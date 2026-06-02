unit SimpleArcSolver;

interface

uses
  System.SysUtils,
  System.Math,
  VehiclePoseSolver;

type
  TVector2D = record
    X: Double;
    Y: Double;
  end;

  TSimpleArcPass = record
    Pass: Integer;
    FinalSteer: Double;
    PathLength: Double;
    PositionError: Double;
    HeadingError: Double;
  end;

  TSimpleArcSolution = record
    Success: Boolean;
    Radius: Double;
    DeltaPsi: Double;
    ArcLength: Double;
    SteerMax: Double;
    ShadowCount: Integer;
    S: Double;
    Sl: Double;
    TurnAngle: Double;
    FinalHeading: Double;
    PositionError: Double;
    HeadingError: Double;
    TerminalPose: TVehiclePose;
    FinalPose: TVehiclePose;
    Passes: TArray<TSimpleArcPass>;
  end;

function SolveSimpleArc(
  const Radius, DeltaPsi, SteerMaxDeg: Double;
  const ShadowCount: Integer = 9
): TSimpleArcSolution;

implementation

function ClampDouble(const Value, AMin, AMax: Double): Double;
begin
  Result := Value;
  if Result < AMin then
    Result := AMin
  else if Result > AMax then
    Result := AMax;
end;

function WrapAngle(const Angle: Double): Double;
begin
  Result := Angle;
  while Result > Pi do
    Result := Result - (2 * Pi);
  while Result < -Pi do
    Result := Result + (2 * Pi);
end;

function NormalizePositiveAngle(const Angle: Double): Double;
begin
  Result := WrapAngle(Angle);
  if Result < 0 then
    Result := Result + (2 * Pi);
end;

function SignedDistanceToLine(const Point, Origin, Direction: TVector2D): Double;
begin
  Result := (Point.X - Origin.X) * Direction.Y - (Point.Y - Origin.Y) * Direction.X;
end;

function AngleDistanceToPerpendicular(const Angle, LineAngle: Double): Double;
var
  Target: Double;
  ErrorValue: Double;
begin
  Result := 1.0E300;
  Target := LineAngle + Pi / 2;
  ErrorValue := Abs(WrapAngle(Angle - Target));
  if ErrorValue < Result then
    Result := ErrorValue;

  Target := LineAngle - Pi / 2;
  ErrorValue := Abs(WrapAngle(Angle - Target));
  if ErrorValue < Result then
    Result := ErrorValue;
end;

function MakeVector(const X, Y: Double): TVector2D;
begin
  Result.X := X;
  Result.Y := Y;
end;

function BuildLocalBisector(const Radius, DeltaPsi: Double; out Center, BisectorDir: TVector2D; out BisectorAngle, TurnAngle: Double): Boolean;
var
  StartAngle: Double;
begin
  Result := (Abs(Radius) > 1e-12) and (DeltaPsi <> 0);
  if not Result then
  begin
    Center := MakeVector(0, 0);
    BisectorDir := MakeVector(0, 0);
    BisectorAngle := 0;
    TurnAngle := 0;
    Exit;
  end;

  Center := MakeVector(0, Radius);
  StartAngle := IfThen(Radius >= 0, -Pi / 2, Pi / 2);
  TurnAngle := IfThen(Radius >= 0, DeltaPsi, -DeltaPsi);
  BisectorAngle := StartAngle + TurnAngle / 2;
  BisectorDir := MakeVector(Cos(BisectorAngle), Sin(BisectorAngle));
end;

function EvaluateLinearSteerPath(
  const Radius, DeltaPsi, SteerMax, FinalSteer, PathLength: Double;
  out TerminalPose: TVehiclePose;
  out PositionError, HeadingError: Double
): Boolean;
var
  Slew: Double;
  Center, BisectorDir, RearPoint: TVector2D;
  BisectorAngle, TurnAngle, TerminalHeading: Double;
  EffectiveSteer: Double;
begin
  Result := False;
  TerminalPose := Default(TVehiclePose);
  PositionError := NaN;
  HeadingError := NaN;

  if not BuildLocalBisector(Radius, DeltaPsi, Center, BisectorDir, BisectorAngle, TurnAngle) then
    Exit;

  if Abs(PathLength) <= 1e-12 then
    Exit;

  EffectiveSteer := FinalSteer;
  if Abs(EffectiveSteer) > SteerMax then
    EffectiveSteer := Sign(EffectiveSteer) * SteerMax;

  Slew := EffectiveSteer / PathLength;
  TerminalPose := SampleVehiclePoseForSlew(0, 0, 0, PathLength, Slew, PathLength, Radius);

  RearPoint := MakeVector(TerminalPose.X, TerminalPose.Y);
  PositionError := Abs(SignedDistanceToLine(RearPoint, Center, BisectorDir));

  TerminalHeading := TerminalPose.Angle;
  HeadingError := AngleDistanceToPerpendicular(TerminalHeading, BisectorAngle);
  Result := True;
end;

function SolveSimpleArc(
  const Radius, DeltaPsi, SteerMaxDeg: Double;
  const ShadowCount: Integer
): TSimpleArcSolution;
type
  TSearchCandidate = record
    FinalSteer: Double;
    PathLength: Double;
    PositionError: Double;
    HeadingError: Double;
    Valid: Boolean;
    TerminalPose: TVehiclePose;
  end;

var
  ArcLength: Double;
  TurnDirection: Integer;
  InitialSteer: Double;
  InitialPathLength: Double;
  MaxPathLength: Double;
  SteerMaxRad: Double;
  MaxSteer: Double;
  SteerMin, SteerMax: Double;
  SteerCenter, PathCenter: Double;
  SteerSpan, PathSpan: Double;
  PositionTolerance: Double;
  HeadingTolerance: Double;
  Best: TSearchCandidate;
  HasBest: Boolean;
  Trace: TArray<TSimpleArcPass>;

  function BetterCandidate(const A, B: TSearchCandidate): Boolean;
  begin
    if not B.Valid then
      Exit(A.Valid);
    if not A.Valid then
      Exit(False);
    if A.PositionError < B.PositionError - 1e-12 then
      Exit(True);
    if A.PositionError > B.PositionError + 1e-12 then
      Exit(False);
    if A.HeadingError < B.HeadingError - 1e-12 then
      Exit(True);
    if A.HeadingError > B.HeadingError + 1e-12 then
      Exit(False);
    Result := False;
  end;

  function EvaluateCandidate(const FinalSteer, PathLength: Double): TSearchCandidate;
  begin
    Result.Valid := EvaluateLinearSteerPath(
      Radius, DeltaPsi, MaxSteer, FinalSteer, PathLength,
      Result.TerminalPose, Result.PositionError, Result.HeadingError
    );
    Result.FinalSteer := FinalSteer;
    Result.PathLength := PathLength;
  end;

  procedure SearchPathCandidates(
    const FixedSteer, Center, Span: Double;
    const Samples: Integer;
    const Floor: Double;
    out BestCandidate: TSearchCandidate;
    out LeftBound, RightBound, NextSpan: Double
  );
  var
    I, PathSamples: Integer;
    T, PathLength, PathMin: Double;
    Candidate: TSearchCandidate;
  begin
    BestCandidate.Valid := False;
    PathSamples := Max(5, Samples);
    PathMin := Max(1e-9, Floor);
    LeftBound := ClampDouble(Center - Span, PathMin, MaxPathLength);
    RightBound := ClampDouble(Center + Span, PathMin, MaxPathLength);

    for I := 0 to PathSamples - 1 do
    begin
      if PathSamples = 1 then
        T := 0
      else
        T := I / (PathSamples - 1);
      PathLength := LeftBound + (RightBound - LeftBound) * T;
      Candidate := EvaluateCandidate(FixedSteer, PathLength);
      if BetterCandidate(Candidate, BestCandidate) then
        BestCandidate := Candidate;
    end;

    NextSpan := Max((RightBound - LeftBound) * 0.25, PathMin);
  end;

  procedure SearchSteerCandidates(
    const FixedPathLength, Center, Span: Double;
    const Samples: Integer;
    const Floor: Double;
    out BestCandidate: TSearchCandidate;
    out LeftBound, RightBound, NextSpan: Double
  );
  var
    I, SteerSamples: Integer;
    T, FinalSteer, SteerFloor: Double;
    Candidate: TSearchCandidate;
  begin
    BestCandidate.Valid := False;
    SteerSamples := Max(5, Samples);
    SteerFloor := Max(1e-9, Floor);
    LeftBound := ClampDouble(Center - Span, SteerMin, SteerMax);
    RightBound := ClampDouble(Center + Span, SteerMin, SteerMax);

    for I := 0 to SteerSamples - 1 do
    begin
      if SteerSamples = 1 then
        T := 0
      else
        T := I / (SteerSamples - 1);
      FinalSteer := LeftBound + (RightBound - LeftBound) * T;
      Candidate := EvaluateCandidate(FinalSteer, FixedPathLength);
      if BetterCandidate(Candidate, BestCandidate) then
        BestCandidate := Candidate;
    end;

    NextSpan := Max((RightBound - LeftBound) * 0.25, SteerFloor);
  end;

  procedure RunStage(const Passes, SteerSamples, PathSamples: Integer; const Shrink, SteerFloor, PathFloor: Double);
  var
    PassIndex: Integer;
    PathBest, SteerBest: TSearchCandidate;
    PathLeft, PathRight, PathNextSpan: Double;
    SteerLeft, SteerRight, SteerNextSpan: Double;
    TraceRow: TSimpleArcPass;
  begin
    for PassIndex := 0 to Passes - 1 do
    begin
      SearchPathCandidates(steerCenter, pathCenter, pathSpan, PathSamples, PathFloor, PathBest, PathLeft, PathRight, PathNextSpan);
      if PathBest.Valid then
      begin
        pathCenter := PathBest.PathLength;
        pathSpan := Max((PathRight - PathLeft) * Shrink, PathFloor);
      end;

      SearchSteerCandidates(pathCenter, steerCenter, steerSpan, SteerSamples, SteerFloor, SteerBest, SteerLeft, SteerRight, SteerNextSpan);
      if SteerBest.Valid then
      begin
        steerCenter := SteerBest.FinalSteer;
        steerSpan := Max((SteerRight - SteerLeft) * Shrink, SteerFloor);
        if BetterCandidate(SteerBest, Best) then
        begin
          Best := SteerBest;
          HasBest := True;
        end;
      end;

      SetLength(Trace, Length(Trace) + 1);
      TraceRow.Pass := Length(Trace) - 1;
      TraceRow.FinalSteer := steerCenter;
      TraceRow.PathLength := pathCenter;
      if SteerBest.Valid then
      begin
        TraceRow.PositionError := SteerBest.PositionError;
        TraceRow.HeadingError := SteerBest.HeadingError;
      end
      else
      begin
        TraceRow.PositionError := NaN;
        TraceRow.HeadingError := NaN;
      end;
      Trace[High(Trace)] := TraceRow;

      if HasBest and (Best.PositionError <= PositionTolerance) and (Best.HeadingError <= HeadingTolerance) then
        Break;
    end;
  end;

var
  ShadowCountSafe: Integer;
begin
  Result := Default(TSimpleArcSolution);

  ArcLength := Abs(Radius) * Abs(DeltaPsi);
  TurnDirection := IfThen(Radius >= 0, 1, -1);
  InitialSteer := TurnDirection * (Pi / 4);
  InitialPathLength := Max(Max(Abs(ArcLength) * 1.25, Abs(Radius) * 1.5), 0.5);
  MaxPathLength := Max(Max(Abs(ArcLength) * 8, Abs(Radius) * 12), 8);
  SteerMaxRad := DegToRad(ClampDouble(SteerMaxDeg, 45, 90));
  MaxSteer := Min(SteerMaxRad, Pi / 2 - 1e-9);
  SteerMin := IfThen(TurnDirection >= 0, 0.0, -MaxSteer);
  SteerMax := IfThen(TurnDirection >= 0, MaxSteer, 0.0);
  PositionTolerance := 1e-5;
  HeadingTolerance := 1e-5;

  SteerCenter := ClampDouble(InitialSteer, SteerMin, SteerMax);
  PathCenter := ClampDouble(InitialPathLength, 1e-9, MaxPathLength);
  SteerSpan := Max(Pi / 6, Abs(InitialSteer) * 0.75 + Pi / 12);
  PathSpan := Max(Max(Abs(InitialPathLength) * 0.75, Abs(ArcLength)), 0.75);
  HasBest := False;
  SetLength(Trace, 0);

  RunStage(5, 9, 9, 0.25, Pi / 180, 1e-3);
  if (not HasBest) or (Best.PositionError > PositionTolerance) or (Best.HeadingError > HeadingTolerance) then
    RunStage(10, 21, 21, 0.2, 1e-7, 1e-7);

  Result.Success := HasBest and (Best.PositionError <= PositionTolerance) and (Best.HeadingError <= HeadingTolerance);
  Result.Radius := Radius;
  Result.DeltaPsi := DeltaPsi;
  Result.ArcLength := ArcLength;
  Result.SteerMax := SteerMaxDeg;
  Result.S := IfThen(HasBest, Best.PathLength, 0);
  Result.Sl := IfThen((HasBest) and (Abs(Best.PathLength) > 1e-12), Best.FinalSteer / Best.PathLength, 0);
  Result.TurnAngle := IfThen(HasBest, Best.FinalSteer, 0);
  Result.FinalHeading := IfThen(HasBest, Best.TerminalPose.Angle, 0);
  Result.PositionError := IfThen(HasBest, Best.PositionError, NaN);
  Result.HeadingError := IfThen(HasBest, Best.HeadingError, NaN);
  if HasBest then
    Result.TerminalPose := Best.TerminalPose
  else
    Result.TerminalPose := Default(TVehiclePose);
  Result.FinalPose := Result.TerminalPose;
  Result.Passes := Trace;

  ShadowCountSafe := ShadowCount;
  if ShadowCountSafe < 2 then
    ShadowCountSafe := 2;
  if ShadowCountSafe > 64 then
    ShadowCountSafe := 64;
  Result.ShadowCount := ShadowCountSafe;
  // The caller can use ShadowCountSafe with BuildVehicleSweepFromTerminalSl-style logic
  // if it wants to render a fading copy sweep.
end;

end.
