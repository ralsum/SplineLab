unit ServerSimpleArcSolver;

{$mode delphi}

interface

uses
  SysUtils,
  Math,
  PoseSolver;

type
  TServerPoint2D = record
    X: Double;
    Y: Double;
  end;

  TServerCoord = record
    X: Double;
    Y: Double;
    Psi: Double;
    Length: Double;
    LabelText: string;
    Color: string;
  end;

  TLinearSteerPoint = record
    X: Double;
    Y: Double;
    Heading: Double;
    Theta: Double;
  end;

  TLinearSteerPath = record
    Points: array of TLinearSteerPoint;
    TerminalPose: TVehiclePose;
  end;

  TTraceCandidate = record
    FinalSteer: Double;
    PathLength: Double;
    Slew: Double;
    PositionError: Double;
    HeadingError: Double;
    HeadingNormalAngle: Double;
    HeadingNormalError: Double;
    HeadingNormalSatisfied: Boolean;
    SteerAtLimit: Boolean;
    Path: TLinearSteerPath;
    Vc: TServerPoint2D;
  end;

  TTracePass = record
    Pass: Integer;
    SteerCenter: Double;
    PathCenter: Double;
    SteerSpan: Double;
    PathSpan: Double;
    TerminalPose: TVehiclePose;
    PathBestValid: Boolean;
    SteerBestValid: Boolean;
    PathBest: TTraceCandidate;
    SteerBest: TTraceCandidate;
  end;

  TServerSimpleArcSolution = record
    Success: Boolean;
    EdgeCase: Boolean;
    EdgeCaseReason: string;
    Radius: Double;
    ArcLength: Double;
    S: Double;
    Sl: Double;
    TurnAngle: Double;
    FinalHeading: Double;
    CurveLength: Double;
    PositionError: Double;
    HeadingError: Double;
    HeadingNormalAngle: Double;
    HeadingNormalError: Double;
    HeadingNormalSatisfied: Boolean;
    Vc: TServerPoint2D;
    TerminalPose: TVehiclePose;
    FinalPose: TVehiclePose;
    TerminalCoord: TServerCoord;
    PathPoints: array of TLinearSteerPoint;
    Passes: array of TTracePass;
  end;

function SolveSimpleArcServer(
  const Radius, DeltaPsi, SteerMax, InitialSl: Double;
  const VehicleX, VehicleY, VehicleAngle: Double
): TServerSimpleArcSolution;

implementation

type
  TArcGeometry = record
    Radius: Double;
    DeltaPsi: Double;
    SteerMax: Double;
  end;

  TArcBisectorGeometry = record
    Valid: Boolean;
    Radius: Double;
    ArcLength: Double;
    TurnAngle: Double;
    Center: TServerPoint2D;
    StartAngle: Double;
    BisectorAngle: Double;
    BisectorOrigin: TServerPoint2D;
    BisectorDir: TServerPoint2D;
  end;

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
    Result := Result - 2 * Pi;
  while Result < -Pi do
    Result := Result + 2 * Pi;
end;

function NormalizePositiveAngle(const Angle: Double): Double;
begin
  Result := WrapAngle(Angle);
  if Result < 0 then
    Result := Result + 2 * Pi;
end;

function SignedDistanceToLine(const Point, Origin, Direction: TServerPoint2D): Double;
begin
  Result := (Point.X - Origin.X) * Direction.Y - (Point.Y - Origin.Y) * Direction.X;
end;

function AngleDistanceToPerpendicular(const Angle, LineAngle: Double): Double;
var
  TargetAngles: array[0..1] of Double;
  Target, ErrorValue, Best: Double;
  I: Integer;
begin
  TargetAngles[0] := LineAngle + Pi / 2;
  TargetAngles[1] := LineAngle - Pi / 2;
  Best := 1.0E300;
  for I := Low(TargetAngles) to High(TargetAngles) do
  begin
    Target := TargetAngles[I];
    ErrorValue := Abs(WrapAngle(Angle - Target));
    if ErrorValue < Best then
      Best := ErrorValue;
  end;
  Result := Best;
end;

function GetVehiclePerpendicularIntersection(
  const Rear, BodyDirection, Front, SteerDirection: TServerPoint2D;
  out Point: TServerPoint2D
): Boolean;
var
  RpNormalOrigin, RpNormalDirection: TServerPoint2D;
  SvNormalOrigin, SvNormalDirection: TServerPoint2D;
  Det, Dx, Dy, T: Double;
begin
  // VCor is the intersection of the normals to Rp and Sv, matching the browser render.
  RpNormalOrigin := Rear;
  RpNormalDirection.X := -BodyDirection.Y;
  RpNormalDirection.Y := BodyDirection.X;
  SvNormalOrigin := Front;
  SvNormalDirection.X := -SteerDirection.Y;
  SvNormalDirection.Y := SteerDirection.X;

  Det := RpNormalDirection.X * SvNormalDirection.Y - RpNormalDirection.Y * SvNormalDirection.X;
  if Abs(Det) < 1e-9 then
  begin
    Point.X := 0;
    Point.Y := 0;
    Exit(False);
  end;

  Dx := SvNormalOrigin.X - RpNormalOrigin.X;
  Dy := SvNormalOrigin.Y - RpNormalOrigin.Y;
  T := (Dx * SvNormalDirection.Y - Dy * SvNormalDirection.X) / Det;
  Point.X := RpNormalOrigin.X + RpNormalDirection.X * T;
  Point.Y := RpNormalOrigin.Y + RpNormalDirection.Y * T;
  Result := True;
end;

function GetSimpleArcGeometry(const Radius, DeltaPsi, SteerMax: Double): TArcGeometry;
begin
  Result.Radius := Radius;
  Result.DeltaPsi := DeltaPsi;
  Result.SteerMax := SteerMax;
end;

function GetArcLength(const Geometry: TArcGeometry): Double;
begin
  Result := Abs(Geometry.Radius) * Abs(Geometry.DeltaPsi);
end;

function GetSimpleArcBisectorGeometry(const Geometry: TArcGeometry): TArcBisectorGeometry;
var
  RadiusValue, ArcLength, TurnAngle, StartAngle, BisectorAngle: Double;
begin
  RadiusValue := Geometry.Radius;
  ArcLength := GetArcLength(Geometry);
  Result.Valid := False;
  Result.Radius := RadiusValue;
  Result.ArcLength := ArcLength;
  Result.TurnAngle := 0;
  Result.Center.X := 0;
  Result.Center.Y := 0;
  Result.StartAngle := 0;
  Result.BisectorAngle := 0;
  Result.BisectorOrigin.X := 0;
  Result.BisectorOrigin.Y := 0;
  Result.BisectorDir.X := 0;
  Result.BisectorDir.Y := 0;

  if (Abs(RadiusValue) > 1e-12) and (ArcLength > 0) then
  begin
    TurnAngle := ArcLength / RadiusValue;
    if RadiusValue >= 0 then
      StartAngle := -Pi / 2
    else
      StartAngle := Pi / 2;
    BisectorAngle := StartAngle + TurnAngle / 2;
    Result.Valid := True;
    Result.Radius := RadiusValue;
    Result.ArcLength := ArcLength;
    Result.TurnAngle := TurnAngle;
    Result.Center.X := 0;
    Result.Center.Y := RadiusValue;
    Result.StartAngle := StartAngle;
    Result.BisectorAngle := BisectorAngle;
    Result.BisectorOrigin := Result.Center;
    Result.BisectorDir.X := Cos(BisectorAngle);
    Result.BisectorDir.Y := Sin(BisectorAngle);
  end;
end;

function IntegrateLinearSteerPath(const FinalSteer, PathLength: Double): TLinearSteerPath;
var
  Count, I: Integer;
  T, Distance, Slew: Double;
  Pose: TVehiclePose;
begin
  Count := Max(2, Ceil(48 + Abs(PathLength) * 96));
  Slew := IfThen(PathLength = 0, 0, FinalSteer / PathLength);
  SetLength(Result.Points, Count);
  for I := 0 to Count - 1 do
  begin
    T := IfThen(Count = 1, 0, I / (Count - 1));
    Distance := PathLength * T;
    Pose := SampleVehiclePoseForSlew(0, 0, 0, Distance, Slew, PathLength, 0);
    Result.Points[I].X := Pose.X;
    Result.Points[I].Y := Pose.Y;
    Result.Points[I].Heading := Pose.Angle;
    Result.Points[I].Theta := Pose.Theta;
  end;
  Result.TerminalPose := SampleVehiclePoseForSlew(0, 0, 0, PathLength, Slew, PathLength, 0);
end;

function GetSimpleArcVC(const TerminalPose: TVehiclePose): TServerPoint2D;
var
  Rear, Front, BodyDirection, SteerDirection: TServerPoint2D;
begin
  Rear.X := TerminalPose.X;
  Rear.Y := TerminalPose.Y;
  BodyDirection.X := Cos(TerminalPose.Angle);
  BodyDirection.Y := Sin(TerminalPose.Angle);
  Front.X := Rear.X + BodyDirection.X;
  Front.Y := Rear.Y + BodyDirection.Y;
  SteerDirection.X := Cos(TerminalPose.Angle + TerminalPose.Theta);
  SteerDirection.Y := Sin(TerminalPose.Angle + TerminalPose.Theta);
  if not GetVehiclePerpendicularIntersection(Rear, BodyDirection, Front, SteerDirection, Result) then
  begin
    Result.X := 0;
    Result.Y := 0;
  end;
end;

function EvaluateCandidate(
  const Geometry: TArcGeometry;
  const Bisector: TArcBisectorGeometry;
  const FinalSteer, PathLength: Double
): TTraceCandidate;
var
  TerminalPose: TVehiclePose;
  Vc: TServerPoint2D;
  BodyDirection, Front: TServerPoint2D;
  SteerDirection: TServerPoint2D;
  SignedPositionError: Double;
  TerminalHeading, HeadingNormalAngle, BisectorHeading: Double;
begin
  Result.FinalSteer := FinalSteer;
  Result.PathLength := PathLength;
  Result.Slew := IfThen(Abs(PathLength) > 1e-12, Abs(FinalSteer) / Abs(PathLength), Abs(FinalSteer));
  Result.SteerAtLimit := Abs(FinalSteer) >= Geometry.SteerMax - 1e-6;
  TerminalPose := IntegrateLinearSteerPath(IfThen(Result.SteerAtLimit, Geometry.SteerMax, FinalSteer), PathLength).TerminalPose;
  Result.Path := IntegrateLinearSteerPath(IfThen(Result.SteerAtLimit, Geometry.SteerMax, FinalSteer), PathLength);
  Vc := GetSimpleArcVC(TerminalPose);
  Result.Vc := Vc;

  SignedPositionError := SignedDistanceToLine(Vc, Bisector.BisectorOrigin, Bisector.BisectorDir);
  Result.PositionError := Abs(SignedPositionError);
  TerminalHeading := TerminalPose.Angle;
  Result.HeadingError := AngleDistanceToPerpendicular(TerminalHeading, Bisector.BisectorAngle);
  HeadingNormalAngle := NormalizePositiveAngle(TerminalHeading + Pi / 2);
  BisectorHeading := NormalizePositiveAngle(Bisector.BisectorAngle);
  Result.HeadingNormalAngle := HeadingNormalAngle;
  Result.HeadingNormalError := Abs(WrapAngle(HeadingNormalAngle - BisectorHeading));
  Result.HeadingNormalSatisfied := Result.HeadingNormalError <= 1e-5;
  Result.Path.TerminalPose := TerminalPose;
end;

function CandidateBetter(const Candidate, CurrentBest: TTraceCandidate): Boolean;
begin
  if Candidate.PositionError < CurrentBest.PositionError - 1e-12 then
    Exit(True);
  if Candidate.PositionError > CurrentBest.PositionError + 1e-12 then
    Exit(False);

  if Candidate.Slew < CurrentBest.Slew - 1e-12 then
    Exit(True);
  if Candidate.Slew > CurrentBest.Slew + 1e-12 then
    Exit(False);

  if Candidate.SteerAtLimit <> CurrentBest.SteerAtLimit then
    Exit(not Candidate.SteerAtLimit);

  if Candidate.HeadingNormalSatisfied <> CurrentBest.HeadingNormalSatisfied then
    Exit(Candidate.HeadingNormalSatisfied);

  if Candidate.HeadingError < CurrentBest.HeadingError - 1e-12 then
    Exit(True);
  if Candidate.HeadingError > CurrentBest.HeadingError + 1e-12 then
    Exit(False);
  Result := False;
end;

function SolveSimpleArcServer(
  const Radius, DeltaPsi, SteerMax, InitialSl: Double;
  const VehicleX, VehicleY, VehicleAngle: Double
): TServerSimpleArcSolution;
var
  Geometry: TArcGeometry;
  Bisector: TArcBisectorGeometry;
  TurnDirection: Double;
  InitialSteer, InitialPathLength, MaxPathLength, MaxSteer: Double;
  SteerMin, SteerMaxBound: Double;
  PositionTolerance, HeadingTolerance, HeadingNormalTolerance: Double;
  SteerCenter, PathCenter, SteerSpan, PathSpan: Double;
  DesiredSlew: Double;
  Best: TTraceCandidate;
  HasBest: Boolean;
  Trace: array of TTracePass;
  PassCount, PathSamples, SteerSamples, Pass, J, I: Integer;
  Shrink, SteerFloor, PathFloor: Double;
  PathSearchBest, SteerSearchBest: TTraceCandidate;
  PathSearchLeft, PathSearchRight, SteerSearchLeft, SteerSearchRight: Double;
  PathLength, FinalSteer: Double;
  PathBest, SteerBest: TTraceCandidate;
  PathBestValid, SteerBestValid: Boolean;
  Count: Integer;
  LocalBestX, LocalBestY: Double;
  PathLeft, PathRight, SteerLeft, SteerRight, Width, Step, XValue, YValue: Double;

  function SearchPathCandidates(const FixedSteer, Center, Span: Double; out BestCandidate: TTraceCandidate; out LeftValue, RightValue: Double): Boolean;
  var
    Samples, Index: Integer;
    PathMin, PathMax, PathT, CandidateSteer: Double;
    Candidate: TTraceCandidate;
    BestLocal: Boolean;
  begin
    Samples := Max(5, PathSamples);
    PathMin := Max(1e-9, PathFloor);
    PathMax := Max(1e-9, MaxPathLength);
    LeftValue := ClampDouble(Center - Span, PathMin, PathMax);
    RightValue := ClampDouble(Center + Span, PathMin, PathMax);
    BestLocal := False;
    BestCandidate := Default(TTraceCandidate);
    for Index := 0 to Samples - 1 do
    begin
      PathT := IfThen(Samples = 1, 0, Index / (Samples - 1));
      PathLength := LeftValue + (RightValue - LeftValue) * PathT;
      Candidate := EvaluateCandidate(Geometry, Bisector, FixedSteer, PathLength);
      Candidate.FinalSteer := FixedSteer;
      Candidate.PathLength := PathLength;
      if (not BestLocal) or CandidateBetter(Candidate, BestCandidate) then
      begin
        BestCandidate := Candidate;
        BestLocal := True;
      end;
    end;
    Result := BestLocal;
  end;

  function SearchSteerCandidates(const FixedPathLength, Center, Span: Double; out BestCandidate: TTraceCandidate; out LeftValue, RightValue: Double): Boolean;
  var
    Samples, Index: Integer;
    SteerT, CandidateSteer: Double;
    Candidate: TTraceCandidate;
    BestLocal: Boolean;
  begin
    Samples := Max(5, SteerSamples);
    LeftValue := ClampDouble(Center - Span, SteerMin, SteerMaxBound);
    RightValue := ClampDouble(Center + Span, SteerMin, SteerMaxBound);
    BestLocal := False;
    BestCandidate := Default(TTraceCandidate);
    for Index := 0 to Samples - 1 do
    begin
      SteerT := IfThen(Samples = 1, 0, Index / (Samples - 1));
      CandidateSteer := LeftValue + (RightValue - LeftValue) * SteerT;
      Candidate := EvaluateCandidate(Geometry, Bisector, CandidateSteer, FixedPathLength);
      Candidate.FinalSteer := CandidateSteer;
      Candidate.PathLength := FixedPathLength;
      if (not BestLocal) or CandidateBetter(Candidate, BestCandidate) then
      begin
        BestCandidate := Candidate;
        BestLocal := True;
      end;
    end;
    Result := BestLocal;
  end;

begin
  Geometry := GetSimpleArcGeometry(Radius, DeltaPsi, SteerMax);
  Bisector := GetSimpleArcBisectorGeometry(Geometry);
  Result := Default(TServerSimpleArcSolution);
  Result.Radius := Radius;
  Result.ArcLength := Abs(Radius) * Abs(DeltaPsi);
  Result.S := Result.ArcLength;
  Result.Sl := IfThen(Abs(Radius) > 1e-12, 1 / Radius, 0);
  Result.TurnAngle := DeltaPsi;
  Result.FinalHeading := 0;
  Result.CurveLength := Result.ArcLength;
  Result.TerminalPose.X := VehicleX;
  Result.TerminalPose.Y := VehicleY;
  Result.TerminalPose.Angle := VehicleAngle;
  Result.TerminalPose.Theta := 0;
  Result.TerminalPose.Radius := Radius;
  Result.TerminalPose.CurveLength := Result.ArcLength;
  Result.FinalPose := Result.TerminalPose;
  Result.TerminalCoord.X := VehicleX;
  Result.TerminalCoord.Y := VehicleY;
  Result.TerminalCoord.Psi := VehicleAngle;
  Result.TerminalCoord.Length := 1;
  Result.TerminalCoord.LabelText := 'Rp';
  Result.TerminalCoord.Color := '#7dd3fc';

  if not Bisector.Valid then
  begin
    Result.Success := False;
    Exit;
  end;

  TurnDirection := IfThen(Radius >= 0, 1.0, -1.0);
  InitialPathLength := Max(Max(Abs(Result.ArcLength), Abs(Radius) * 1.5), 0.5);
  MaxPathLength := Max(Max(Abs(Result.ArcLength) * 8, Abs(Radius) * 12), 8);
  MaxSteer := Max(DegToRad(45), Min(Abs(SteerMax), Pi / 2 - 1e-9));
  SteerMin := IfThen(TurnDirection >= 0, 0, -MaxSteer);
  SteerMaxBound := IfThen(TurnDirection >= 0, MaxSteer, 0);
  DesiredSlew := Abs(InitialSl);
  if DesiredSlew <= 1e-12 then
    DesiredSlew := IfThen(Abs(InitialPathLength) > 1e-12, MaxSteer / Abs(InitialPathLength), MaxSteer);
  InitialSteer := ClampDouble(TurnDirection * DesiredSlew * InitialPathLength, SteerMin, SteerMaxBound);
  PositionTolerance := 1e-5;
  HeadingTolerance := 1e-5;
  HeadingNormalTolerance := 1e-5;
  SteerCenter := ClampDouble(InitialSteer, SteerMin, SteerMaxBound);
  PathCenter := ClampDouble(InitialPathLength, 1e-9, MaxPathLength);
  SteerSpan := Max(Pi / 6, Abs(InitialSteer) * 0.75 + Pi / 12);
  PathSpan := Max(Max(Abs(InitialPathLength) * 0.75, Abs(Result.ArcLength)), 0.75);
  SetLength(Trace, 0);
  HasBest := False;
  PassCount := 5;
  PathSamples := 9;
  SteerSamples := 9;
  Shrink := 0.25;
  SteerFloor := Pi / 180;
  PathFloor := 1e-3;
  Best := Default(TTraceCandidate);

  for J := 0 to 1 do
  begin
    if J = 1 then
    begin
      PassCount := 10;
      PathSamples := 21;
      SteerSamples := 21;
      Shrink := 0.2;
      SteerFloor := 1e-7;
      PathFloor := 1e-7;
    end;

    for Pass := 0 to PassCount - 1 do
    begin
      PathBestValid := SearchPathCandidates(SteerCenter, PathCenter, PathSpan, PathSearchBest, PathSearchLeft, PathSearchRight);
      if PathBestValid then
      begin
        PathCenter := PathSearchBest.PathLength;
        if PathSearchBest.PositionError <= PositionTolerance * 4 then
          PathSpan := Max((PathSearchRight - PathSearchLeft) * Shrink, PathFloor)
        else
          PathSpan := Min(MaxPathLength, Max(PathSearchBest.PathLength * 0.5, PathSpan * 1.25));
      end;

      SteerBestValid := SearchSteerCandidates(PathCenter, SteerCenter, SteerSpan, SteerSearchBest, SteerSearchLeft, SteerSearchRight);
      if SteerBestValid then
      begin
        SteerCenter := SteerSearchBest.FinalSteer;
        if SteerSearchBest.PositionError <= PositionTolerance * 4 then
          SteerSpan := Max((SteerSearchRight - SteerSearchLeft) * Shrink, SteerFloor)
        else
          SteerSpan := Max(SteerSpan, Abs(SteerSearchBest.FinalSteer) * 0.5 + SteerFloor);
        if (not HasBest) or CandidateBetter(SteerSearchBest, Best) then
        begin
          Best := SteerSearchBest;
          HasBest := True;
        end;
      end;

      if (not SteerBestValid) or (SteerSearchBest.PositionError > PositionTolerance * 4) then
        SteerCenter := ClampDouble(TurnDirection * DesiredSlew * PathCenter, SteerMin, SteerMaxBound);

      SetLength(Trace, Length(Trace) + 1);
      Trace[High(Trace)].Pass := Length(Trace) - 1;
      Trace[High(Trace)].SteerCenter := SteerCenter;
      Trace[High(Trace)].PathCenter := PathCenter;
      Trace[High(Trace)].SteerSpan := SteerSpan;
      Trace[High(Trace)].PathSpan := PathSpan;
      Trace[High(Trace)].PathBestValid := PathBestValid;
      Trace[High(Trace)].SteerBestValid := SteerBestValid;
      if PathBestValid then
        Trace[High(Trace)].PathBest := PathSearchBest;
      if SteerBestValid then
      begin
        Trace[High(Trace)].SteerBest := SteerSearchBest;
        Trace[High(Trace)].TerminalPose := SteerSearchBest.Path.TerminalPose;
      end;

      if (not HasBest) then
        Break;
      if (Best.PositionError <= PositionTolerance) and (Best.HeadingNormalSatisfied) and (Best.HeadingError <= HeadingTolerance) then
        Break;
    end;

    if HasBest and (Best.PositionError <= PositionTolerance) and (Best.HeadingNormalSatisfied) and (Best.HeadingError <= HeadingTolerance) then
      Break;
  end;

  if not HasBest then
  begin
    Result.Success := False;
    Result.Passes := Trace;
    Exit;
  end;

  Result.Success := (Best.PositionError <= PositionTolerance) and (Best.HeadingNormalSatisfied) and (Best.HeadingError <= HeadingTolerance);
  Result.EdgeCase := (Abs(Best.FinalSteer) >= MaxSteer - 1e-6) and (Best.PositionError > PositionTolerance);
  if Result.EdgeCase then
    Result.EdgeCaseReason := 'steer-max-reached-before-bisector'
  else
    Result.EdgeCaseReason := '';
  Result.S := Best.PathLength;
  Result.Sl := IfThen(Best.PathLength <> 0, Best.FinalSteer / Best.PathLength, 0);
  Result.TurnAngle := Best.FinalSteer;
  Result.FinalHeading := Best.Path.TerminalPose.Angle;
  Result.CurveLength := Best.PathLength;
  Result.PositionError := Best.PositionError;
  Result.HeadingError := Best.HeadingError;
  Result.HeadingNormalAngle := Best.HeadingNormalAngle;
  Result.HeadingNormalError := Best.HeadingNormalError;
  Result.HeadingNormalSatisfied := Best.HeadingNormalSatisfied;
  Result.Vc := Best.Vc;
  Result.TerminalPose := Best.Path.TerminalPose;
  Result.FinalPose := Best.Path.TerminalPose;
  Result.PathPoints := Best.Path.Points;
  Result.TerminalCoord.X := Best.Path.TerminalPose.X;
  Result.TerminalCoord.Y := Best.Path.TerminalPose.Y;
  Result.TerminalCoord.Psi := Best.Path.TerminalPose.Angle;
  Result.TerminalCoord.Length := 1;
  Result.TerminalCoord.LabelText := 'Rp';
  Result.TerminalCoord.Color := '#7dd3fc';
  Result.Passes := Trace;
end;

end.
