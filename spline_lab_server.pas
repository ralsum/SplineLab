program SplineLabServer;

{$mode delphi}

uses
  Classes,
  SysUtils,
  StrUtils,
  fphttpserver,
  httpdefs,
  PoseSolver,
  ServerSimpleArcSolver;

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
    '"theta":' + JsonFloat(Pose.Theta) + ',' +
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
    '"theta":' + JsonFloat(Point.Theta) +
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

function JsonTraceCandidate(const Candidate: TTraceCandidate): string;
begin
  Result := '{' +
    '"finalSteer":' + JsonFloat(Candidate.FinalSteer) + ',' +
    '"pathLength":' + JsonFloat(Candidate.PathLength) + ',' +
    '"positionError":' + JsonFloat(Candidate.PositionError) + ',' +
    '"headingError":' + JsonFloat(Candidate.HeadingError) + ',' +
    '"headingNormalError":' + JsonFloat(Candidate.HeadingNormalError) + ',' +
    '"headingNormalSatisfied":' + JsonBool(Candidate.HeadingNormalSatisfied) +
  '}';
end;

function JsonTracePass(const Pass: TTracePass): string;
begin
  Result := '{' +
    '"pass":' + IntToStr(Pass.Pass) + ',' +
    '"steerCenter":' + JsonFloat(Pass.SteerCenter) + ',' +
    '"pathCenter":' + JsonFloat(Pass.PathCenter) + ',' +
    '"steerSpan":' + JsonFloat(Pass.SteerSpan) + ',' +
    '"pathSpan":' + JsonFloat(Pass.PathSpan) + ',' +
    '"terminalPose":' + JsonPose(Pass.TerminalPose) + ',' +
    '"pathBest":' + IfThen(Pass.PathBestValid, JsonTraceCandidate(Pass.PathBest), 'null') + ',' +
    '"steerBest":' + IfThen(Pass.SteerBestValid, JsonTraceCandidate(Pass.SteerBest), 'null') +
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
  BaseX, BaseY, BaseAngle, Distance, Slew, CurveLength, Radius: Double;
  Pose: TVehiclePose;
  ArcRadius, ArcDeltaPsi, ArcSteerMax, InitialSl: Double;
  Solution: TServerSimpleArcSolution;
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
    Distance := ParseQueryFloat(Request.URI, 'distance', 0);
    Slew := ParseQueryFloat(Request.URI, 'headingChangePerDistance', ParseQueryFloat(Request.URI, 'slew', 0));
    CurveLength := ParseQueryFloat(Request.URI, 'curveLength', 0);
    Radius := ParseQueryFloat(Request.URI, 'radius', 0);
    Pose := SampleVehiclePoseForSlew(BaseX, BaseY, BaseAngle, Distance, Slew, CurveLength, Radius);
    SendJsonResponse(
      Response,
      200,
      '{' +
        '"ok":true,' +
        '"pose":{' +
          '"x":' + JsonFloat(Pose.X) + ',' +
          '"y":' + JsonFloat(Pose.Y) + ',' +
          '"angle":' + JsonFloat(Pose.Angle) + ',' +
          '"theta":' + JsonFloat(Pose.Theta) + ',' +
          '"radius":' + JsonFloat(Pose.Radius) + ',' +
          '"curveLength":' + JsonFloat(Pose.CurveLength) +
        '}' +
      '}'
    );
    Exit;
  end;

  if SameText(Copy(StripQuery(Request.URI), 1, Length('/api/solve-simple-arc')), '/api/solve-simple-arc') then
  begin
    ArcRadius := ParseQueryFloat(Request.URI, 'radius', 1);
    ArcDeltaPsi := ParseQueryFloat(Request.URI, 'deltaPsi', Pi / 2);
    ArcSteerMax := ParseQueryFloat(Request.URI, 'steerMax', Pi / 2);
    InitialSl := ParseQueryFloat(Request.URI, 'slew', ParseQueryFloat(Request.URI, 'initialSl', 1.14));
    BaseX := ParseQueryFloat(Request.URI, 'vehicleX', 0);
    BaseY := ParseQueryFloat(Request.URI, 'vehicleY', 0);
    BaseAngle := ParseQueryFloat(Request.URI, 'vehicleAngle', 0);
    Solution := SolveSimpleArcServer(ArcRadius, ArcDeltaPsi, ArcSteerMax, InitialSl, BaseX, BaseY, BaseAngle);
    SendJsonResponse(
      Response,
      200,
      '{' +
        '"ok":true,' +
        '"success":' + JsonBool(Solution.Success) + ',' +
        '"edgeCase":' + JsonBool(Solution.EdgeCase) + ',' +
        '"edgeCaseReason":' + JsonString(Solution.EdgeCaseReason) + ',' +
        '"radius":' + JsonFloat(Solution.Radius) + ',' +
        '"arcLength":' + JsonFloat(Solution.ArcLength) + ',' +
        '"s":' + JsonFloat(Solution.S) + ',' +
        '"sl":' + JsonFloat(Solution.Sl) + ',' +
        '"slew":' + JsonFloat(Solution.Sl) + ',' +
        '"turnAngle":' + JsonFloat(Solution.TurnAngle) + ',' +
        '"finalHeading":' + JsonFloat(Solution.FinalHeading) + ',' +
        '"theta":' + JsonFloat(Solution.TerminalPose.Theta) + ',' +
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
