program SplineLabServer;

{$mode delphi}

uses
  Classes,
  SysUtils,
  Math,
  StrUtils,
  fphttpserver,
  httpdefs,
  PoseSolver,
  ServerSimpleArcSolver,
  StarterSeedCreator;

function libc_isatty(fd: LongInt): LongInt; cdecl; external 'c' name 'isatty';

type
  TStaticServer = class
  private
    FBaseDir: string;
    function ResolveRequestPath(const URI: string): string;
    function ResolveQueryValue(const URI, Name: string): string;
    function ParseQueryFloat(const URI, Name: string; const Default: Double): Double;
    function GuessMimeType(const FileName: string): string;
    procedure SendTextResponse(var Response: TFPHTTPConnectionResponse; const Code: Integer; const CodeText, Body: string);
    procedure SendJsonResponse(var Response: TFPHTTPConnectionResponse; const Code: Integer; const Body: string);
    function ReadLaunchStatus: string;
    procedure RequestHandler(Sender: TObject; var Request: TFPHTTPConnectionRequest; var Response: TFPHTTPConnectionResponse);
  public
    constructor Create(const ABaseDir: string);
    procedure Run(const Port: Word);
  end;

function NormalizeSlashes(const Value: string): string;
begin
  Result := StringReplace(Value, '/', PathDelim, [rfReplaceAll]);
end;

function StripQuery(const URI: string): string;
var
  QueryPos: SizeInt;
begin
  QueryPos := Pos('?', URI);
  if QueryPos > 0 then
    Result := Copy(URI, 1, QueryPos - 1)
  else
    Result := URI;
end;

function TrimLeadingSlash(const Value: string): string;
begin
  Result := Value;
  while (Result <> '') and (Result[1] = '/') do
    Delete(Result, 1, 1);
end;

function JsonFloat(const Value: Double): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := FormatFloat('0.###############', Value, FS);
end;

function JsonBool(const Value: Boolean): string;
begin
  if Value then
    Result := 'true'
  else
    Result := 'false';
end;

function ClampDouble(const Value, AMin, AMax: Double): Double;
begin
  Result := Value;
  if Result < AMin then
    Result := AMin
  else if Result > AMax then
    Result := AMax;
end;

function JsonString(const Value: string): string;
var
  I: Integer;
  Ch: Char;
begin
  Result := '"';
  for I := 1 to Length(Value) do
  begin
    Ch := Value[I];
    case Ch of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      Result := Result + Ch;
    end;
  end;
  Result := Result + '"';
end;

function JsonPoint2D(const X, Y: Double): string;
begin
  Result := '{"x":' + JsonFloat(X) + ',"y":' + JsonFloat(Y) + '}';
end;

function JsonPose(const Pose: TVehiclePose): string;
begin
  Result := '{' +
    '"x":' + JsonFloat(Pose.X) + ',' +
    '"y":' + JsonFloat(Pose.Y) + ',' +
    '"angle":' + JsonFloat(Pose.Angle) + ',' +
    '"strAng":' + JsonFloat(Pose.SteerAngle) + ',' +
    '"radius":' + JsonFloat(Pose.Radius) + ',' +
    '"curveLength":' + JsonFloat(Pose.CurveLength) +
  '}';
end;

function JsonCoord(const Coord: TServerCoord): string;
begin
  Result := '{' +
    '"X":' + JsonFloat(Coord.X) + ',' +
    '"Y":' + JsonFloat(Coord.Y) + ',' +
    '"Psi":' + JsonFloat(Coord.Psi) + ',' +
    '"length":' + JsonFloat(Coord.Length) + ',' +
    '"label":' + JsonString(Coord.LabelText) + ',' +
    '"color":' + JsonString(Coord.Color) +
  '}';
end;

function JsonPathPoint(const Point: TLinearSteerPoint): string;
begin
  Result := '{' +
    '"x":' + JsonFloat(Point.X) + ',' +
    '"y":' + JsonFloat(Point.Y) + ',' +
    '"heading":' + JsonFloat(Point.Heading) + ',' +
    '"strAng":' + JsonFloat(Point.SteerAngle) +
  '}';
end;

function JsonPathPoints(const Points: array of TLinearSteerPoint): string;
var
  I: Integer;
begin
  Result := '[';
  for I := Low(Points) to High(Points) do
  begin
    if I > Low(Points) then
      Result := Result + ',';
    Result := Result + JsonPathPoint(Points[I]);
  end;
  Result := Result + ']';
end;

function JsonTracePass(const Pass: TTracePass): string;
begin
  Result := '{' +
    '"hEst":' + IntToStr(Pass.HEst) + ',' +
    '"pass":' + IntToStr(Pass.Pass) + ',' +
    '"steerCenter":' + JsonFloat(Pass.SteerCenter) + ',' +
    '"pathCenter":' + JsonFloat(Pass.PathCenter) + ',' +
    '"swtd":' + JsonFloat(Pass.Swtd) + ',' +
    '"s":' + JsonFloat(Pass.Swtd) + ',' +
    '"curveLength":' + JsonFloat(Pass.Swtd) + ',' +
    '"desStrAng":' + JsonFloat(Pass.DesiredSteerAngle) + ',' +
    '"headingChange":' + JsonFloat(Pass.HeadingChange) + ',' +
    '"turnAngle":' + JsonFloat(Pass.HeadingChange) + ',' +
    '"strAng":' + JsonFloat(Pass.HeadingChange) + ',' +
    '"hRt":' + JsonFloat(Pass.HeadingChangePerDistance) + ',' +
    '"headingChangePerDistance":' + JsonFloat(Pass.HeadingChangePerDistance) + ',' +
    '"slew":' + JsonFloat(Pass.HeadingChangePerDistance) + ',' +
    '"sl":' + JsonFloat(Pass.HeadingChangePerDistance) + ',' +
    '"pErr":' + JsonFloat(Pass.PErr) + ',' +
    '"dPErr":' + JsonFloat(Pass.DPErr) + ',' +
    '"hErr":' + JsonFloat(Pass.HErr) + ',' +
    '"vc":' + JsonPoint2D(Pass.Vc.X, Pass.Vc.Y) + ',' +
    '"complexVc":' + JsonPoint2D(Pass.Vc.X, Pass.Vc.Y) + ',' +
    '"steerSpan":' + JsonFloat(Pass.SteerSpan) + ',' +
    '"pathSpan":' + JsonFloat(Pass.PathSpan) + ',' +
    '"terminalPose":' + JsonPose(Pass.TerminalPose) + ',' +
    '"finalPose":' + JsonPose(Pass.TerminalPose) + ',' +
    '"complexTerminalPose":' + JsonPose(Pass.TerminalPose) +
  '}';
end;

function JsonTracePasses(const Passes: array of TTracePass): string;
var
  I: Integer;
begin
  Result := '[';
  for I := Low(Passes) to High(Passes) do
  begin
    if I > Low(Passes) then
      Result := Result + ',';
    Result := Result + JsonTracePass(Passes[I]);
  end;
  Result := Result + ']';
end;

function JsonDoubleArray(const Values: array of Double): string;
var
  I: Integer;
begin
  Result := '[';
  for I := Low(Values) to High(Values) do
  begin
    if I > Low(Values) then
      Result := Result + ',';
    Result := Result + JsonFloat(Values[I]);
  end;
  Result := Result + ']';
end;

function JsonStarterSeedCell(const Cell: TStarterSeedCell): string;
begin
  Result := '{' +
    '"stepIndex":' + IntToStr(Cell.StepIndex) + ',' +
    '"radiusIndex":' + IntToStr(Cell.RadiusIndex) + ',' +
    '"radius":' + JsonFloat(Cell.Radius) + ',' +
    '"radiusAxisValue":' + JsonFloat(Cell.RadiusAxisValue) + ',' +
    '"rawPsiDegrees":' + JsonFloat(Cell.RawPsiDegrees) + ',' +
    '"swtd":' + JsonFloat(Cell.Swtd) + ',' +
    '"desStrAng":' + JsonFloat(Cell.DesStrAng) + ',' +
    '"source":' + JsonString(Cell.Source) + ',' +
    '"confidence":' + JsonFloat(Cell.Confidence) +
  '}';
end;

function JsonStarterSeedRow(const Row: TStarterSeedRow): string;
var
  I: Integer;
begin
  Result := '[';
  for I := Low(Row) to High(Row) do
  begin
    if I > Low(Row) then
      Result := Result + ',';
    Result := Result + JsonStarterSeedCell(Row[I]);
  end;
  Result := Result + ']';
end;

function JsonStarterSeedGrid(const Grid: TStarterSeedGrid): string;
var
  I: Integer;
begin
  Result := '[';
  for I := Low(Grid) to High(Grid) do
  begin
    if I > Low(Grid) then
      Result := Result + ',';
    Result := Result + JsonStarterSeedRow(Grid[I]);
  end;
  Result := Result + ']';
end;

function JsonServerSimpleArcSolution(const Solution: TServerSimpleArcSolution): string;
begin
  Result := '{' +
    '"ok":true,' +
    '"success":' + JsonBool(Solution.Success) + ',' +
    '"edgeCase":' + JsonBool(Solution.EdgeCase) + ',' +
    '"edgeCaseReason":' + JsonString(Solution.EdgeCaseReason) + ',' +
    '"radius":' + JsonFloat(Solution.Radius) + ',' +
    '"swtd":' + JsonFloat(Solution.S) + ',' +
    '"headingChange":' + JsonFloat(Solution.TurnAngle) + ',' +
    '"headingChangePerDistance":' + JsonFloat(Solution.Sl) + ',' +
    '"arcLength":' + JsonFloat(Solution.ArcLength) + ',' +
    '"s":' + JsonFloat(Solution.S) + ',' +
    '"sl":' + JsonFloat(Solution.Sl) + ',' +
    '"slew":' + JsonFloat(Solution.Sl) + ',' +
    '"turnAngle":' + JsonFloat(Solution.TurnAngle) + ',' +
    '"finalHeading":' + JsonFloat(Solution.FinalHeading) + ',' +
    '"strAng":' + JsonFloat(Solution.TerminalPose.SteerAngle) + ',' +
    '"curveLength":' + JsonFloat(Solution.CurveLength) + ',' +
    '"steeredWheelTravelDistance":' + JsonFloat(Solution.CurveLength) + ',' +
    '"positionError":' + JsonFloat(Solution.PositionError) + ',' +
    '"headingError":' + JsonFloat(Solution.HeadingError) + ',' +
    '"headingNormalAngle":' + JsonFloat(Solution.HeadingNormalAngle) + ',' +
    '"headingNormalError":' + JsonFloat(Solution.HeadingNormalError) + ',' +
    '"headingNormalSatisfied":' + JsonBool(Solution.HeadingNormalSatisfied) + ',' +
    '"vc":' + JsonPoint2D(Solution.Vc.X, Solution.Vc.Y) + ',' +
    '"complexVc":' + JsonPoint2D(Solution.Vc.X, Solution.Vc.Y) + ',' +
    '"terminalPose":' + JsonPose(Solution.TerminalPose) + ',' +
    '"complexTerminalPose":' + JsonPose(Solution.TerminalPose) + ',' +
    '"finalPose":' + JsonPose(Solution.FinalPose) + ',' +
    '"terminalCoord":' + JsonCoord(Solution.TerminalCoord) + ',' +
    '"terminalRadius":' + JsonFloat(Sqrt(Sqr(Solution.Vc.X - Solution.TerminalPose.X) + Sqr(Solution.Vc.Y - Solution.TerminalPose.Y))) + ',' +
    '"pathPoints":' + JsonPathPoints(Solution.PathPoints) + ',' +
    '"passes":' + JsonTracePasses(Solution.Passes) +
  '}';
end;

function IsFiniteDouble(const Value: Double): Boolean;
begin
  Result := (not IsNan(Value)) and (Abs(Value) < 1.0E300);
end;

function IsPassingStarterSeedSolution(const Solution: TServerSimpleArcSolution): Boolean;
begin
  Result := Solution.Success
    and Solution.HeadingNormalSatisfied
    and IsFiniteDouble(Solution.PositionError)
    and IsFiniteDouble(Solution.HeadingError)
    and (Solution.PositionError <= 1e-7)
    and (Solution.HeadingError <= 1e-7);
end;

function NormalizeStarterSeedCell(
  const Seed: TStarterSeedCell;
  const Radius, RawPsiDegrees: Double;
  const Source: string;
  const Confidence: Double
): TStarterSeedCell;
begin
  Result := Seed;
  Result.Radius := Radius;
  Result.RawPsiDegrees := RawPsiDegrees;
  Result.Source := Source;
  Result.Confidence := Confidence;
end;

function GetFinalTracePass(const Solution: TServerSimpleArcSolution): TTracePass;
begin
  Result := Default(TTracePass);
  if Length(Solution.Passes) > 0 then
    Result := Solution.Passes[High(Solution.Passes)];
end;

function BuildStarterSeedRefinementCandidates(
  const BaseSeed: TStarterSeedCell;
  const Solution: TServerSimpleArcSolution
): TStarterSeedRow;
var
  FinalPass: TTracePass;
  CenterSeed, Candidate: TStarterSeedCell;
  SwtdCenter, SwtdStep, DesCenter, DesStep: Double;
  Count: Integer;
  PositiveP, PositiveH: Boolean;

  procedure AppendUniqueCandidate(const Seed: TStarterSeedCell);
  var
    Index: Integer;
  begin
    for Index := 0 to Count - 1 do
    begin
      if (Abs(Result[Index].Swtd - Seed.Swtd) < 1e-12)
        and (Abs(Result[Index].DesStrAng - Seed.DesStrAng) < 1e-12) then
        Exit;
    end;
    SetLength(Result, Count + 1);
    Result[Count] := Seed;
    Inc(Count);
  end;

begin
  SetLength(Result, 0);
  Count := 0;
  FinalPass := GetFinalTracePass(Solution);
  if IsFiniteDouble(FinalPass.Swtd) then
    SwtdCenter := Max(1e-6, FinalPass.Swtd)
  else
    SwtdCenter := Max(1e-6, BaseSeed.Swtd);
  if IsFiniteDouble(FinalPass.DesiredSteerAngle) then
    DesCenter := FinalPass.DesiredSteerAngle
  else
    DesCenter := BaseSeed.DesStrAng;
  SwtdStep := Max(SwtdCenter * 0.005, 1e-6);
  DesStep := Max(Pi / 720, Abs(DesCenter) * 0.005);
  PositiveP := FinalPass.PErr >= 0;
  PositiveH := FinalPass.HErr >= 0;

  CenterSeed := BaseSeed;
  CenterSeed.Swtd := SwtdCenter;
  CenterSeed.DesStrAng := ClampDouble(DesCenter, 0, Pi / 2);
  CenterSeed.Source := 'starter-refine-center';
  CenterSeed.Confidence := 0.99;
  AppendUniqueCandidate(CenterSeed);

  Candidate := CenterSeed;
  Candidate.Swtd := Max(1e-6, SwtdCenter - SwtdStep);
  Candidate.Source := 'starter-refine-swtd-low';
  Candidate.Confidence := 0.97;
  AppendUniqueCandidate(Candidate);

  Candidate := CenterSeed;
  Candidate.Swtd := SwtdCenter + SwtdStep;
  Candidate.Source := 'starter-refine-swtd-high';
  Candidate.Confidence := 0.965;
  AppendUniqueCandidate(Candidate);

  Candidate := CenterSeed;
  Candidate.DesStrAng := ClampDouble(DesCenter - DesStep, 0, Pi / 2);
  Candidate.Source := 'starter-refine-des-low';
  Candidate.Confidence := 0.96;
  AppendUniqueCandidate(Candidate);

  Candidate := CenterSeed;
  Candidate.DesStrAng := ClampDouble(DesCenter + DesStep, 0, Pi / 2);
  Candidate.Source := 'starter-refine-des-high';
  Candidate.Confidence := 0.955;
  AppendUniqueCandidate(Candidate);

  Candidate := CenterSeed;
  if PositiveP then
    Candidate.Swtd := Max(1e-6, SwtdCenter - SwtdStep)
  else
    Candidate.Swtd := SwtdCenter + SwtdStep;
  if PositiveH then
    Candidate.DesStrAng := ClampDouble(DesCenter - DesStep, 0, Pi / 2)
  else
    Candidate.DesStrAng := ClampDouble(DesCenter + DesStep, 0, Pi / 2);
  Candidate.Source := 'starter-refine-diagonal-a';
  Candidate.Confidence := 0.95;
  AppendUniqueCandidate(Candidate);

  Candidate := CenterSeed;
  if PositiveP then
    Candidate.Swtd := SwtdCenter + SwtdStep
  else
    Candidate.Swtd := Max(1e-6, SwtdCenter - SwtdStep);
  if PositiveH then
    Candidate.DesStrAng := ClampDouble(DesCenter + DesStep, 0, Pi / 2)
  else
    Candidate.DesStrAng := ClampDouble(DesCenter - DesStep, 0, Pi / 2);
  Candidate.Source := 'starter-refine-diagonal-b';
  Candidate.Confidence := 0.945;
  AppendUniqueCandidate(Candidate);
end;

function EscapeJsonString(const Value: string): string;
begin
  Result := JsonString(Value);
end;

constructor TStaticServer.Create(const ABaseDir: string);
begin
  inherited Create;
  FBaseDir := IncludeTrailingPathDelimiter(ExpandFileName(ABaseDir));
end;

function TStaticServer.ResolveRequestPath(const URI: string): string;
var
  RelPath, AbsPath: string;
begin
  RelPath := TrimLeadingSlash(StripQuery(URI));
  if (RelPath = '') or (RelPath = 'index.html') then
    RelPath := 'spline-lab.html';

  RelPath := NormalizeSlashes(RelPath);
  if Pos('..', RelPath) > 0 then
    Exit('');

  AbsPath := ExpandFileName(FBaseDir + RelPath);

  Result := AbsPath;
end;

function TStaticServer.ResolveQueryValue(const URI, Name: string): string;
var
  Query, Token: string;
  TokenPos, ValueStart, ValueEnd: SizeInt;
begin
  Result := '';
  Query := URI;
  TokenPos := Pos('?', Query);
  if TokenPos > 0 then
    Query := Copy(Query, TokenPos + 1, MaxInt)
  else
    Exit;
  Token := Name + '=';
  TokenPos := Pos(Token, Query);
  while TokenPos > 0 do
  begin
    if (TokenPos = 1) or (Query[TokenPos - 1] = '&') then
    begin
      ValueStart := TokenPos + Length(Token);
      ValueEnd := ValueStart;
      while (ValueEnd <= Length(Query)) and (Query[ValueEnd] <> '&') do
        Inc(ValueEnd);
      Result := Copy(Query, ValueStart, ValueEnd - ValueStart);
      Exit;
    end;
    TokenPos := PosEx(Token, Query, TokenPos + Length(Token));
  end;
end;

function TStaticServer.ParseQueryFloat(const URI, Name: string; const Default: Double): Double;
var
  Raw: string;
  FS: TFormatSettings;
begin
  Raw := ResolveQueryValue(URI, Name);
  if Raw = '' then
    Exit(Default);

  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  if not TryStrToFloat(Raw, Result, FS) then
    Result := Default;
end;

function TStaticServer.GuessMimeType(const FileName: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(FileName));
  if Ext = '.html' then
    Result := 'text/html; charset=utf-8'
  else if Ext = '.css' then
    Result := 'text/css; charset=utf-8'
  else if Ext = '.js' then
    Result := 'application/javascript; charset=utf-8'
  else if Ext = '.json' then
    Result := 'application/json; charset=utf-8'
  else if Ext = '.svg' then
    Result := 'image/svg+xml'
  else if Ext = '.png' then
    Result := 'image/png'
  else if (Ext = '.jpg') or (Ext = '.jpeg') then
    Result := 'image/jpeg'
  else if Ext = '.gif' then
    Result := 'image/gif'
  else if Ext = '.ico' then
    Result := 'image/x-icon'
  else if Ext = '.txt' then
    Result := 'text/plain; charset=utf-8'
  else
    Result := 'application/octet-stream';
end;

procedure TStaticServer.SendTextResponse(var Response: TFPHTTPConnectionResponse; const Code: Integer; const CodeText, Body: string);
var
  Stream: TStringStream;
begin
  Stream := TStringStream.Create(Body);
  Response.Code := Code;
  Response.CodeText := CodeText;
  Response.ContentType := 'text/plain; charset=utf-8';
  Response.ContentStream := Stream;
  Response.FreeContentStream := True;
end;

procedure TStaticServer.SendJsonResponse(var Response: TFPHTTPConnectionResponse; const Code: Integer; const Body: string);
var
  Stream: TStringStream;
begin
  Stream := TStringStream.Create(Body);
  Response.Code := Code;
  Response.CodeText := 'OK';
  Response.ContentType := 'application/json; charset=utf-8';
  Response.ContentStream := Stream;
  Response.FreeContentStream := True;
end;

function TStaticServer.ReadLaunchStatus: string;
var
  StatusPath: string;
  Lines: TStringList;
begin
  StatusPath := '/tmp/openclaw-control-status.txt';
  Lines := TStringList.Create;
  try
    if FileExists(StatusPath) then
    begin
      Lines.LoadFromFile(StatusPath);
      Result := Trim(Lines.Text);
    end
    else
      Result := 'OpenClaw control launching...';
  finally
    Lines.Free;
  end;

  if Result = '' then
    Result := 'OpenClaw control launching...';
end;

procedure TStaticServer.RequestHandler(Sender: TObject; var Request: TFPHTTPConnectionRequest; var Response: TFPHTTPConnectionResponse);
var
  FilePath, EffectivePath: string;
  Stream: TFileStream;
  HEst: Integer;
  BaseX, BaseY, BaseAngle, Swtd, HeadingChange, HeadingChangePerDistance: Double;
  Pose: TVehiclePose;
  ArcRadius, ArcDeltaPsi, SwtdSeed, ArcSteerMax, InitialSl, DesiredSteerAngleSeed: Double;
  Solution: TServerSimpleArcSolution;
  StarterGrid: TStarterSeedGrid;
  StarterCandidates: TStarterSeedRow;
  RefinementCandidates: TStarterSeedRow;
  StarterSeed: TStarterSeedCell;
  CandidateIndex, BestIndex: Integer;
  CandidateSeed, BestSeed: TStarterSeedCell;
  CandidateSolution: TServerSimpleArcSolution;
  BestScore, CandidateScore: Double;
  Passed: Boolean;
begin
  if (Request.Method <> 'GET') and (Request.Method <> 'HEAD') then
  begin
    Response.CustomHeaders.Values['Allow'] := 'GET, HEAD';
    SendTextResponse(Response, 405, 'Method Not Allowed', 'Only GET and HEAD are supported.' + LineEnding);
    Exit;
  end;

  if SameText(Copy(StripQuery(Request.URI), 1, Length('/api/sample-pose')), '/api/sample-pose') then
  begin
    BaseX := ParseQueryFloat(Request.URI, 'baseX', 0);
    BaseY := ParseQueryFloat(Request.URI, 'baseY', 0);
    BaseAngle := ParseQueryFloat(Request.URI, 'baseAngle', 0);
    Swtd := ParseQueryFloat(Request.URI, 'swtd', ParseQueryFloat(Request.URI, 'distance', 0));
    HeadingChange := ParseQueryFloat(Request.URI, 'headingChange', ParseQueryFloat(Request.URI, 'deltaPsi', 0));
    HeadingChangePerDistance := ParseQueryFloat(Request.URI, 'headingChangePerDistance', ParseQueryFloat(Request.URI, 'slew', 0));
    if Abs(HeadingChangePerDistance) < 1e-12 then
    begin
      if Abs(Swtd) > 1e-12 then
        HeadingChangePerDistance := HeadingChange / Swtd
      else
        HeadingChangePerDistance := 0;
    end;
    Pose := SampleVehiclePoseForSlew(BaseX, BaseY, BaseAngle, Swtd, HeadingChangePerDistance, Abs(Swtd), 0);
    SendJsonResponse(
      Response,
      200,
      '{' +
        '"ok":true,' +
        '"pose":{' +
          '"x":' + JsonFloat(Pose.X) + ',' +
          '"y":' + JsonFloat(Pose.Y) + ',' +
          '"angle":' + JsonFloat(Pose.Angle) + ',' +
          '"strAng":' + JsonFloat(Pose.SteerAngle) + ',' +
          '"radius":' + JsonFloat(Pose.Radius) + ',' +
          '"curveLength":' + JsonFloat(Pose.CurveLength) +
        '}' +
      '}'
    );
    Exit;
  end;

  if SameText(Copy(StripQuery(Request.URI), 1, Length('/api/solve-simple-arc')), '/api/solve-simple-arc') then
  begin
    SwtdSeed := ParseQueryFloat(Request.URI, 'swtd', ParseQueryFloat(Request.URI, 'distance', 0.000001));
    ArcRadius := ParseQueryFloat(Request.URI, 'radius', 1);
    ArcDeltaPsi := ParseQueryFloat(Request.URI, 'deltaPsi', ParseQueryFloat(Request.URI, 'headingChange', Pi / 2));
    ArcSteerMax := ParseQueryFloat(Request.URI, 'steerMax', Pi / 2);
    InitialSl := ParseQueryFloat(Request.URI, 'headingChangePerDistance', ParseQueryFloat(Request.URI, 'slew', ParseQueryFloat(Request.URI, 'initialSl', 1.14)));
    DesiredSteerAngleSeed := ParseQueryFloat(Request.URI, 'desStrAng', InitialSl * SwtdSeed);
    BaseX := ParseQueryFloat(Request.URI, 'vehicleX', 0);
    BaseY := ParseQueryFloat(Request.URI, 'vehicleY', 0);
    BaseAngle := ParseQueryFloat(Request.URI, 'vehicleAngle', 0);
    HEst := StrToIntDef(ResolveQueryValue(Request.URI, 'hEst'), 0);
    Solution := SolveSimpleArcEstimatorServer(
      ArcRadius,
      ArcDeltaPsi,
      SwtdSeed,
      DesiredSteerAngleSeed,
      ArcSteerMax,
      BaseX,
      BaseY,
      BaseAngle,
      HEst
    );
    SendJsonResponse(Response, 200, JsonServerSimpleArcSolution(Solution));
    Exit;
  end;

  if SameText(Copy(StripQuery(Request.URI), 1, Length('/api/starter-seed-solve')), '/api/starter-seed-solve') then
  begin
    ArcRadius := ParseQueryFloat(Request.URI, 'radius', 1);
    ArcDeltaPsi := ParseQueryFloat(Request.URI, 'rawPsiDegrees', 90);
    ArcSteerMax := ParseQueryFloat(Request.URI, 'steerMaxDegrees', 90);
    BaseX := ParseQueryFloat(Request.URI, 'vehicleX', 0);
    BaseY := ParseQueryFloat(Request.URI, 'vehicleY', 0);
    BaseAngle := ParseQueryFloat(Request.URI, 'vehicleAngle', 0);
    HEst := StrToIntDef(ResolveQueryValue(Request.URI, 'hEst'), 0);
    StarterCandidates := BuildStarterSeedCandidates(ArcRadius, ArcDeltaPsi);
    if Length(StarterCandidates) = 0 then
      StarterCandidates := BuildStarterSeedCandidates(1, 90);
    Solution := Default(TServerSimpleArcSolution);
    StarterSeed := GetStarterSeedForRequest(ArcRadius, ArcDeltaPsi);
    ArcSteerMax := DegToRad(ArcSteerMax);
    if ArcSteerMax <= 0 then
      ArcSteerMax := Pi / 2;
    BestScore := MaxDouble;
    BestIndex := -1;
    Passed := False;
    for CandidateIndex := Low(StarterCandidates) to High(StarterCandidates) do
    begin
      CandidateSeed := StarterCandidates[CandidateIndex];
      CandidateSolution := SolveSimpleArcEstimatorServer(
        ArcRadius,
        DegToRad(ArcDeltaPsi),
        CandidateSeed.Swtd,
        CandidateSeed.DesStrAng,
        ArcSteerMax,
        BaseX,
        BaseY,
        BaseAngle,
        HEst
      );
      CandidateScore := CandidateSolution.PositionError + CandidateSolution.HeadingError;
      if IsPassingStarterSeedSolution(CandidateSolution) then
      begin
        Solution := CandidateSolution;
        StarterSeed := CandidateSeed;
        BestIndex := CandidateIndex;
        Passed := True;
        Break;
      end;
      if CandidateScore < BestScore then
      begin
        BestScore := CandidateScore;
        BestIndex := CandidateIndex;
        BestSeed := CandidateSeed;
        Solution := CandidateSolution;
      end;
    end;
    if (not Passed) and (BestIndex >= 0) and (Length(Solution.Passes) > 0) then
    begin
      RefinementCandidates := BuildStarterSeedRefinementCandidates(BestSeed, Solution);
      for CandidateIndex := Low(RefinementCandidates) to High(RefinementCandidates) do
      begin
        CandidateSeed := RefinementCandidates[CandidateIndex];
        CandidateSolution := SolveSimpleArcEstimatorServer(
          ArcRadius,
          DegToRad(ArcDeltaPsi),
          CandidateSeed.Swtd,
          CandidateSeed.DesStrAng,
          ArcSteerMax,
          BaseX,
          BaseY,
          BaseAngle,
          HEst
        );
        if IsPassingStarterSeedSolution(CandidateSolution) then
        begin
          Solution := CandidateSolution;
          StarterSeed := CandidateSeed;
          BestIndex := 1000 + CandidateIndex;
          Passed := True;
          Break;
        end;
        CandidateScore := CandidateSolution.PositionError + CandidateSolution.HeadingError;
        if CandidateScore < BestScore then
        begin
          BestScore := CandidateScore;
          BestIndex := 1000 + CandidateIndex;
          BestSeed := CandidateSeed;
          Solution := CandidateSolution;
        end;
      end;
    end;
    if (not Passed) and (BestIndex >= 0) then
      StarterSeed := BestSeed;
    SendJsonResponse(
      Response,
      200,
      '{' +
        '"ok":true,' +
        '"radius":' + JsonFloat(ArcRadius) + ',' +
        '"rawPsiDegrees":' + JsonFloat(ArcDeltaPsi) + ',' +
        '"steerMaxDegrees":' + JsonFloat(ArcSteerMax * 180 / Pi) + ',' +
        '"passed":' + JsonBool(IsPassingStarterSeedSolution(Solution)) + ',' +
        '"selectedCandidateIndex":' + IntToStr(BestIndex) + ',' +
        '"selectedCandidate":' + JsonStarterSeedCell(StarterSeed) + ',' +
        '"starterSeedCandidates":' + JsonStarterSeedRow(StarterCandidates) + ',' +
        '"solution":' + JsonServerSimpleArcSolution(Solution) +
      '}'
    );
    Exit;
  end;

  if SameText(Copy(StripQuery(Request.URI), 1, Length('/api/openclaw-status')), '/api/openclaw-status') then
  begin
    SendJsonResponse(
      Response,
      200,
      '{' +
        '"ok":true,' +
        '"message":' + EscapeJsonString(ReadLaunchStatus) +
      '}'
    );
    Exit;
  end;

  if SameText(Copy(StripQuery(Request.URI), 1, Length('/api/starter-seeds')), '/api/starter-seeds') then
  begin
    StarterGrid := BuildStarterSeedGrid;
    StarterSeed := GetStarterSeedForRequest(
      ParseQueryFloat(Request.URI, 'radius', 1),
      ParseQueryFloat(Request.URI, 'rawPsiDegrees', 90)
    );
    SendJsonResponse(
      Response,
      200,
      '{' +
        '"ok":true,' +
        '"radiusAxis":' + JsonDoubleArray(StarterSeedRadiusAxis) + ',' +
        '"rawPsiAxis":' + JsonDoubleArray(StarterSeedRawPsiAxis) + ',' +
        '"starterSeedGrid":' + JsonStarterSeedGrid(StarterGrid) + ',' +
        '"starterSeed":' + JsonStarterSeedCell(StarterSeed) +
      '}'
    );
    Exit;
  end;

  FilePath := ResolveRequestPath(Request.URI);
  if FilePath = '' then
  begin
    SendTextResponse(Response, 403, 'Forbidden', 'Forbidden.' + LineEnding);
    Exit;
  end;

  if DirectoryExists(FilePath) then
    FilePath := IncludeTrailingPathDelimiter(FilePath) + 'index.html';

  if not FileExists(FilePath) then
  begin
    if SameText(ExtractFileName(FilePath), 'spline-lab.html') then
      EffectivePath := IncludeTrailingPathDelimiter(FBaseDir) + 'spline-lab.html'
    else
      EffectivePath := '';
  end
  else
    EffectivePath := FilePath;

  if (EffectivePath = '') or (not FileExists(EffectivePath)) then
  begin
    SendTextResponse(Response, 404, 'Not Found', 'Not found.' + LineEnding);
    Exit;
  end;

  Stream := TFileStream.Create(EffectivePath, fmOpenRead or fmShareDenyNone);
  Response.Code := 200;
  Response.CodeText := 'OK';
  Response.ContentType := GuessMimeType(EffectivePath);
  if Request.Method = 'HEAD' then
    Stream.Free
  else
  begin
    Response.ContentStream := Stream;
    Response.FreeContentStream := True;
  end;
end;

procedure TStaticServer.Run(const Port: Word);
var
  Server: TFPHTTPServer;
begin
  Server := TFPHTTPServer.Create(nil);
  try
    Server.Port := Port;
    Server.Threaded := False;
    Server.OnRequest := RequestHandler;
    Server.Active := True;
    Writeln('Serving ', FBaseDir, ' on http://0.0.0.0:', Port);

    // Stay alive even when launched without an attached terminal.
    if libc_isatty(0) = 1 then
      ReadLn
    else
      while True do
        Sleep(1000);
  finally
    Server.Free;
  end;
end;

var
  BaseDir, Port: string;
  PortNumber: Word;
  Server: TStaticServer;
begin
  BaseDir := ExtractFilePath(ExpandFileName(ParamStr(0)));
  if ParamCount > 0 then
    Port := ParamStr(1)
  else if GetEnvironmentVariable('VECTOR_VIEWER_PORT') <> '' then
    Port := GetEnvironmentVariable('VECTOR_VIEWER_PORT')
  else
    Port := '8792';

  PortNumber := StrToIntDef(Port, 8792);
  Server := TStaticServer.Create(BaseDir);
  try
    Server.Run(PortNumber);
  finally
    Server.Free;
  end;
end.
