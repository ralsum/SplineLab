unit ServerSimpleArcSolver;

{$mode delphi}

interface

uses
  SysUtils,
  Math,
  PoseSolver,
  SimpleArcSolver;

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
    SteerAngle: Double;
  end;

  TTracePass = record
    HEst: Integer;
    Pass: Integer;
    SteerCenter: Double;
    PathCenter: Double;
    SteerSpan: Double;
    PathSpan: Double;
    DesiredSteerAngle: Double;
    Swtd: Double;
    HeadingChange: Double;
    HeadingChangePerDistance: Double;
    PErr: Double;
    DPErr: Double;
    HErr: Double;
    Vc: TServerPoint2D;
    TerminalPose: TVehiclePose;
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
  const Swtd, HeadingChange, SteerMax, HeadingChangePerDistanceSeed: Double;
  const VehicleX, VehicleY, VehicleAngle: Double
): TServerSimpleArcSolution;

function SolveSimpleArcEstimatorServer(
  const TargetRadius, TargetDeltaPsi, SeedSwtd, DesiredSteerAngle, SteerMax: Double;
  const VehicleX, VehicleY, VehicleAngle: Double;
  const HEst: Integer
): TServerSimpleArcSolution;

implementation

const
  MinSwtd = 0.000001;

function NormalizePositiveAngle(const Angle: Double): Double;
begin
  Result := Angle;
  while Result > Pi do
    Result := Result - 2 * Pi;
  while Result < -Pi do
    Result := Result + 2 * Pi;
  if Result < 0 then
    Result := Result + 2 * Pi;
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
  SteerDirection.X := Cos(TerminalPose.Angle + TerminalPose.SteerAngle);
  SteerDirection.Y := Sin(TerminalPose.Angle + TerminalPose.SteerAngle);
  if not GetVehiclePerpendicularIntersection(Rear, BodyDirection, Front, SteerDirection, Result) then
  begin
    Result.X := 0;
    Result.Y := 0;
  end;
end;

function IsFiniteDouble(const Value: Double): Boolean;
begin
  Result := (not IsNan(Value)) and (Abs(Value) < 1e300);
end;

function LimitSwtdMinimum(const Value: Double): Double;
begin
  if IsFiniteDouble(Value) and (Value >= MinSwtd) then
    Result := Value
  else
    Result := MinSwtd;
end;

function NormalizeSlew(const Value: Double): Double;
begin
  if IsFiniteDouble(Value) then
    Result := Value
  else
    Result := 0;
end;

function WrapAngle(const Angle: Double): Double;
begin
  Result := Angle;
  while Result > Pi do
    Result := Result - 2 * Pi;
  while Result < -Pi do
    Result := Result + 2 * Pi;
end;

function SignedBisectorDistance(
  const Vc: TServerPoint2D;
  const Bisector: TArcBisectorGeometry
): Double;
var
  NormalX, NormalY, LengthValue: Double;
  OffsetX, OffsetY: Double;
begin
  if not Bisector.Valid then
    Exit(NaN);

  NormalX := -Bisector.BisectorDir.Y;
  NormalY := Bisector.BisectorDir.X;
  LengthValue := Hypot(NormalX, NormalY);
  if LengthValue <= 1e-12 then
    Exit(NaN);

  OffsetX := Vc.X - Bisector.Center.X;
  OffsetY := Vc.Y - Bisector.Center.Y;
  Result := (OffsetX * (NormalX / LengthValue)) + (OffsetY * (NormalY / LengthValue));
end;

function SignedHeadingNormalError(
  const TerminalPose: TVehiclePose;
  const Bisector: TArcBisectorGeometry
): Double;
begin
  if not Bisector.Valid then
    Exit(NaN);
  Result := WrapAngle((TerminalPose.Angle + Pi / 2) - Bisector.BisectorAngle + Pi);
end;

function PassSwtd(const Pass: TTracePass): Double;
begin
  Result := LimitSwtdMinimum(Pass.Swtd);
  if not IsFiniteDouble(Result) then
    Result := LimitSwtdMinimum(Pass.PathCenter);
end;

function ChoosePositiveRootNear(
  const Roots: array of Double;
  const Anchor: Double
): Double;
var
  I: Integer;
  Candidate, BestDistance, DistanceValue: Double;
begin
  Result := NaN;
  BestDistance := MaxDouble;
  for I := Low(Roots) to High(Roots) do
  begin
    Candidate := Roots[I];
    if IsFiniteDouble(Candidate) and (Candidate >= MinSwtd) then
    begin
      DistanceValue := Abs(Candidate - Anchor);
      if DistanceValue < BestDistance then
      begin
        BestDistance := DistanceValue;
        Result := Candidate;
      end;
    end;
  end;
end;

function EstimateQuadraticRoot(
  const X0, Y0, X1, Y1, X2, Y2: Double
): Double;
var
  D0, D1, D2, A, B, C, Discriminant, RootSpread: Double;
  Roots: array[0..1] of Double;
begin
  Result := NaN;
  if (Abs(X0 - X1) <= 1e-12) or (Abs(X0 - X2) <= 1e-12) or (Abs(X1 - X2) <= 1e-12) then
    Exit;

  D0 := (X0 - X1) * (X0 - X2);
  D1 := (X1 - X0) * (X1 - X2);
  D2 := (X2 - X0) * (X2 - X1);
  A := (Y0 / D0) + (Y1 / D1) + (Y2 / D2);
  B := -(Y0 * (X1 + X2) / D0) - (Y1 * (X0 + X2) / D1) - (Y2 * (X0 + X1) / D2);
  C := (Y0 * X1 * X2 / D0) + (Y1 * X0 * X2 / D1) + (Y2 * X0 * X1 / D2);

  if Abs(A) > 1e-12 then
  begin
    Discriminant := (B * B) - (4 * A * C);
    if Discriminant < 0 then
      Exit;
    RootSpread := Sqrt(Discriminant);
    Roots[0] := (-B - RootSpread) / (2 * A);
    Roots[1] := (-B + RootSpread) / (2 * A);
    Result := ChoosePositiveRootNear(Roots, X2);
  end
  else if Abs(B) > 1e-12 then
  begin
    Roots[0] := -C / B;
    Result := ChoosePositiveRootNear(Slice(Roots, 1), X2);
  end;
end;

function SolveQuadraticCoefficientsRootNear(
  const ConstantValue, LinearValue, QuadraticValue, Anchor: Double
): Double;
var
  Discriminant, RootSpread: Double;
  Roots: array[0..1] of Double;
begin
  Result := NaN;
  if Abs(QuadraticValue) > 1e-12 then
  begin
    Discriminant := (LinearValue * LinearValue) - (4 * QuadraticValue * ConstantValue);
    if Discriminant < -1e-12 then
      Exit;
    if Abs(Discriminant) <= 1e-12 then
    begin
      Roots[0] := -LinearValue / (2 * QuadraticValue);
      Result := ChoosePositiveRootNear(Slice(Roots, 1), Anchor);
      Exit;
    end;
    RootSpread := Sqrt(Discriminant);
    Roots[0] := (-LinearValue - RootSpread) / (2 * QuadraticValue);
    Roots[1] := (-LinearValue + RootSpread) / (2 * QuadraticValue);
    Result := ChoosePositiveRootNear(Roots, Anchor);
  end
  else if Abs(LinearValue) > 1e-12 then
  begin
    Roots[0] := -ConstantValue / LinearValue;
    Result := ChoosePositiveRootNear(Slice(Roots, 1), Anchor);
  end;
end;

procedure MultiplyPolynomialByLinear(
  const Coefficients: array of Double;
  const Root: Double;
  out ResultCoefficients: array of Double
);
var
  I: Integer;
begin
  for I := Low(ResultCoefficients) to High(ResultCoefficients) do
    ResultCoefficients[I] := 0;
  for I := Low(Coefficients) to High(Coefficients) do
  begin
    ResultCoefficients[I] := ResultCoefficients[I] - Coefficients[I] * Root;
    ResultCoefficients[I + 1] := ResultCoefficients[I + 1] + Coefficients[I];
  end;
end;

procedure InterpolatePolynomialCoefficients(
  const XValues, YValues: array of Double;
  out Coefficients: array of Double
);
var
  I, J, K, Count: Integer;
  Denominator, Scale: Double;
  Basis, NextBasis: array[0..3] of Double;
begin
  Count := Length(XValues);
  for I := Low(Coefficients) to High(Coefficients) do
    Coefficients[I] := 0;

  for I := 0 to Count - 1 do
  begin
    Denominator := 1;
    for K := Low(Basis) to High(Basis) do
      Basis[K] := 0;
    Basis[0] := 1;
    for J := 0 to Count - 1 do
    begin
      if I = J then
        Continue;
      Denominator := Denominator * (XValues[I] - XValues[J]);
      MultiplyPolynomialByLinear(Slice(Basis, Count - 1), XValues[J], NextBasis);
      Basis := NextBasis;
    end;
    if Abs(Denominator) <= 1e-12 then
      Continue;
    Scale := YValues[I] / Denominator;
    for K := 0 to Count - 1 do
      Coefficients[K] := Coefficients[K] + Basis[K] * Scale;
  end;
end;

function SolveCubicRootNear(
  const Coefficients: array of Double;
  const Anchor: Double
): Double;
var
  ConstantValue, LinearValue, QuadraticValue, CubicValue: Double;
  A, B, C, P, Q, Discriminant, RootSpread, U, RadiusValue, AcosInput, AngleValue: Double;
  Roots: array[0..2] of Double;
begin
  Result := NaN;
  ConstantValue := Coefficients[0];
  LinearValue := Coefficients[1];
  QuadraticValue := Coefficients[2];
  CubicValue := Coefficients[3];

  if Abs(CubicValue) <= 1e-12 then
  begin
    Result := SolveQuadraticCoefficientsRootNear(ConstantValue, LinearValue, QuadraticValue, Anchor);
    Exit;
  end;

  A := QuadraticValue / CubicValue;
  B := LinearValue / CubicValue;
  C := ConstantValue / CubicValue;
  P := B - (A * A / 3);
  Q := (2 * A * A * A / 27) - (A * B / 3) + C;
  Discriminant := (Q * Q / 4) + (P * P * P / 27);

  if Discriminant > 1e-12 then
  begin
    RootSpread := Sqrt(Discriminant);
    Roots[0] := Sign((-Q / 2) + RootSpread) * Power(Abs((-Q / 2) + RootSpread), 1 / 3)
      + Sign((-Q / 2) - RootSpread) * Power(Abs((-Q / 2) - RootSpread), 1 / 3)
      - (A / 3);
    Result := ChoosePositiveRootNear(Slice(Roots, 1), Anchor);
  end
  else if Abs(Discriminant) <= 1e-12 then
  begin
    U := Sign(-Q / 2) * Power(Abs(-Q / 2), 1 / 3);
    Roots[0] := (2 * U) - (A / 3);
    Roots[1] := (-U) - (A / 3);
    Result := ChoosePositiveRootNear(Slice(Roots, 2), Anchor);
  end
  else
  begin
    RadiusValue := 2 * Sqrt(-P / 3);
    AcosInput := (-Q / 2) / Sqrt(-(P * P * P) / 27);
    if AcosInput < -1 then
      AcosInput := -1
    else if AcosInput > 1 then
      AcosInput := 1;
    AngleValue := ArcCos(AcosInput);
    Roots[0] := (RadiusValue * Cos(AngleValue / 3)) - (A / 3);
    Roots[1] := (RadiusValue * Cos((AngleValue + 2 * Pi) / 3)) - (A / 3);
    Roots[2] := (RadiusValue * Cos((AngleValue + 4 * Pi) / 3)) - (A / 3);
    Result := ChoosePositiveRootNear(Roots, Anchor);
  end;
end;

function EstimatePassSwtd(
  const PassIndex: Integer;
  const Passes: array of TTracePass;
  const FallbackSwtd: Double
): Double;
var
  PreviousSwtd, BasePerr, FirstSwtd, SecondSwtd, DeltaError, EstimatedSwtd: Double;
  XValues, YValues, Coefficients: array[0..3] of Double;
  I, StartIndex, J, K: Integer;
  Distinct: Boolean;
begin
  if PassIndex > 0 then
    PreviousSwtd := PassSwtd(Passes[PassIndex - 1])
  else
    PreviousSwtd := LimitSwtdMinimum(FallbackSwtd);

  Result := PreviousSwtd;
  if PassIndex = 0 then
    Exit;

  if PassIndex = 1 then
  begin
    BasePerr := Passes[PassIndex - 1].PErr;
    if BasePerr > 0 then
      Exit(LimitSwtdMinimum(PreviousSwtd * 0.5));
    if BasePerr < 0 then
      Exit(LimitSwtdMinimum(PreviousSwtd * 2.0));
  end;

  if PassIndex = 2 then
  begin
    FirstSwtd := PassSwtd(Passes[0]);
    SecondSwtd := PassSwtd(Passes[1]);
    DeltaError := Passes[1].PErr - Passes[0].PErr;
    if IsFiniteDouble(FirstSwtd) and IsFiniteDouble(SecondSwtd) and IsFiniteDouble(Passes[0].PErr)
      and IsFiniteDouble(Passes[1].PErr) and (Abs(DeltaError) > 1e-12) then
    begin
      EstimatedSwtd := SecondSwtd - (Passes[1].PErr * (SecondSwtd - FirstSwtd) / DeltaError);
      if IsFiniteDouble(EstimatedSwtd) then
        Exit(LimitSwtdMinimum(EstimatedSwtd));
    end;
  end;

  if PassIndex = 3 then
  begin
    EstimatedSwtd := EstimateQuadraticRoot(
      PassSwtd(Passes[0]), Passes[0].PErr,
      PassSwtd(Passes[1]), Passes[1].PErr,
      PassSwtd(Passes[2]), Passes[2].PErr
    );
    if IsFiniteDouble(EstimatedSwtd) then
      Exit(LimitSwtdMinimum(EstimatedSwtd));
  end;

  if PassIndex >= 4 then
  begin
    StartIndex := PassIndex - 4;
    Distinct := True;
    for I := 0 to 3 do
    begin
      XValues[I] := PassSwtd(Passes[StartIndex + I]);
      YValues[I] := Passes[StartIndex + I].PErr;
      if (not IsFiniteDouble(XValues[I])) or (not IsFiniteDouble(YValues[I])) then
        Distinct := False;
    end;
    for J := 0 to 3 do
      for K := J + 1 to 3 do
        if Abs(XValues[J] - XValues[K]) <= 1e-12 then
          Distinct := False;
    if Distinct then
    begin
      InterpolatePolynomialCoefficients(XValues, YValues, Coefficients);
      EstimatedSwtd := SolveCubicRootNear(Coefficients, XValues[3]);
      if IsFiniteDouble(EstimatedSwtd) then
        Exit(LimitSwtdMinimum(EstimatedSwtd));
    end;
  end;
end;

function MakeEstimatorPass(
  const PassIndex, HEst: Integer;
  const Swtd, DesiredSteerAngle, TargetRadius, TargetDeltaPsi, SteerMax: Double;
  const VehicleX, VehicleY, VehicleAngle: Double;
  const PreviousPErr: Double
): TTracePass;
var
  Hrt: Double;
  LowSolution: TServerSimpleArcSolution;
  VehicleVector: TVehicleVector;
  ArcGeometry: TArcGeometry;
  Bisector: TArcBisectorGeometry;
begin
  Hrt := NormalizeSlew(DesiredSteerAngle / LimitSwtdMinimum(Swtd));
  LowSolution := SolveSimpleArcServer(Swtd, DesiredSteerAngle, SteerMax, Hrt, VehicleX, VehicleY, VehicleAngle);

  VehicleVector.X := VehicleX;
  VehicleVector.Y := VehicleY;
  VehicleVector.Angle := VehicleAngle;
  VehicleVector.Length := 1;
  ArcGeometry.Radius := TargetRadius;
  ArcGeometry.HeadingChange := TargetDeltaPsi;
  ArcGeometry.MaxHeadingChange := Pi * 2;
  Bisector := GetCurrentTurnBisectorGeometry(VehicleVector, ArcGeometry);

  Result := Default(TTracePass);
  Result.HEst := HEst;
  Result.Pass := PassIndex;
  Result.SteerCenter := DesiredSteerAngle;
  Result.PathCenter := LimitSwtdMinimum(Swtd);
  Result.SteerSpan := 0;
  Result.PathSpan := 0;
  Result.DesiredSteerAngle := DesiredSteerAngle;
  Result.Swtd := LimitSwtdMinimum(Swtd);
  Result.HeadingChange := DesiredSteerAngle;
  Result.HeadingChangePerDistance := Hrt;
  Result.Vc := LowSolution.Vc;
  Result.TerminalPose := LowSolution.TerminalPose;
  Result.PErr := SignedBisectorDistance(Result.Vc, Bisector);
  Result.HErr := SignedHeadingNormalError(Result.TerminalPose, Bisector);
  if PassIndex = 0 then
    Result.DPErr := Result.PErr
  else
    Result.DPErr := PreviousPErr - Result.PErr;
end;

function SolveSimpleArcServer(
  const Swtd, HeadingChange, SteerMax, HeadingChangePerDistanceSeed: Double;
  const VehicleX, VehicleY, VehicleAngle: Double
): TServerSimpleArcSolution;
var
  TerminalPose: TVehiclePose;
  HeadingChangePerDistance: Double;
  SafeSwtd: Double;
  Vc: TServerPoint2D;
begin
  SafeSwtd := Swtd;
  if Abs(SafeSwtd) < 1e-12 then
    SafeSwtd := 0;

  if Abs(HeadingChangePerDistanceSeed) > 1e-12 then
    HeadingChangePerDistance := HeadingChangePerDistanceSeed
  else if Abs(SafeSwtd) > 1e-12 then
    HeadingChangePerDistance := HeadingChange / SafeSwtd
  else
    HeadingChangePerDistance := 0;

  if (HeadingChangePerDistance <> HeadingChangePerDistance) or (Abs(HeadingChangePerDistance) > 1e300) then
    HeadingChangePerDistance := 0;

  TerminalPose := SampleVehiclePoseForSlew(
    VehicleX,
    VehicleY,
    VehicleAngle,
    SafeSwtd,
    HeadingChangePerDistance,
    Abs(SafeSwtd),
    0
  );
  Vc := GetSimpleArcVC(TerminalPose);

  Result := Default(TServerSimpleArcSolution);
  Result.Success := True;
  Result.EdgeCase := False;
  Result.EdgeCaseReason := '';
  Result.Radius := 0;
  Result.ArcLength := Abs(SafeSwtd);
  Result.S := SafeSwtd;
  Result.Sl := HeadingChangePerDistance;
  Result.TurnAngle := HeadingChange;
  Result.FinalHeading := TerminalPose.Angle;
  Result.CurveLength := Abs(SafeSwtd);
  Result.PositionError := 0;
  Result.HeadingError := 0;
  Result.HeadingNormalAngle := NormalizePositiveAngle(TerminalPose.Angle + Pi / 2);
  Result.HeadingNormalError := 0;
  Result.HeadingNormalSatisfied := True;
  Result.Vc := Vc;
  Result.TerminalPose := TerminalPose;
  Result.FinalPose := TerminalPose;
  Result.TerminalCoord.X := TerminalPose.X;
  Result.TerminalCoord.Y := TerminalPose.Y;
  Result.TerminalCoord.Psi := TerminalPose.Angle;
  Result.TerminalCoord.Length := 1;
  Result.TerminalCoord.LabelText := 'Rp';
  Result.TerminalCoord.Color := '#7dd3fc';

  SetLength(Result.PathPoints, 1);
  Result.PathPoints[0].X := TerminalPose.X;
  Result.PathPoints[0].Y := TerminalPose.Y;
  Result.PathPoints[0].Heading := TerminalPose.Angle;
  Result.PathPoints[0].SteerAngle := TerminalPose.SteerAngle;

  SetLength(Result.Passes, 1);
  Result.Passes[0].Pass := 0;
  Result.Passes[0].HEst := 0;
  Result.Passes[0].SteerCenter := HeadingChange;
  Result.Passes[0].PathCenter := SafeSwtd;
  Result.Passes[0].SteerSpan := 0;
  Result.Passes[0].PathSpan := 0;
  Result.Passes[0].DesiredSteerAngle := HeadingChange;
  Result.Passes[0].Swtd := SafeSwtd;
  Result.Passes[0].HeadingChange := HeadingChange;
  Result.Passes[0].HeadingChangePerDistance := HeadingChangePerDistance;
  Result.Passes[0].PErr := 0;
  Result.Passes[0].DPErr := 0;
  Result.Passes[0].HErr := 0;
  Result.Passes[0].Vc := Vc;
  Result.Passes[0].TerminalPose := TerminalPose;
end;

function SolveSimpleArcEstimatorServer(
  const TargetRadius, TargetDeltaPsi, SeedSwtd, DesiredSteerAngle, SteerMax: Double;
  const VehicleX, VehicleY, VehicleAngle: Double;
  const HEst: Integer
): TServerSimpleArcSolution;
const
  MaxPassCount = 8;
var
  PassIndex: Integer;
  EstimatedSwtd, PreviousPErr, SafeSeedSwtd, SafeDesiredSteerAngle: Double;
  LatestPass: TTracePass;
begin
  SafeSeedSwtd := LimitSwtdMinimum(SeedSwtd);
  SafeDesiredSteerAngle := DesiredSteerAngle;
  Result := SolveSimpleArcServer(SafeSeedSwtd, SafeDesiredSteerAngle, SteerMax, NormalizeSlew(SafeDesiredSteerAngle / SafeSeedSwtd), VehicleX, VehicleY, VehicleAngle);
  Result.Radius := TargetRadius;
  SetLength(Result.Passes, 0);
  PreviousPErr := NaN;
  for PassIndex := 0 to MaxPassCount - 1 do
  begin
    EstimatedSwtd := EstimatePassSwtd(PassIndex, Result.Passes, SafeSeedSwtd);
    LatestPass := MakeEstimatorPass(
      PassIndex,
      HEst,
      EstimatedSwtd,
      SafeDesiredSteerAngle,
      TargetRadius,
      TargetDeltaPsi,
      SteerMax,
      VehicleX,
      VehicleY,
      VehicleAngle,
      PreviousPErr
    );
    SetLength(Result.Passes, Length(Result.Passes) + 1);
    Result.Passes[High(Result.Passes)] := LatestPass;
    PreviousPErr := LatestPass.PErr;
    if (IsFiniteDouble(LatestPass.PErr) and (Abs(LatestPass.PErr) < 0.001))
      or (IsFiniteDouble(LatestPass.DPErr) and (Abs(LatestPass.DPErr) < 0.001)) then
      Break;
  end;

  if Length(Result.Passes) > 0 then
  begin
    LatestPass := Result.Passes[High(Result.Passes)];
    Result.S := LatestPass.Swtd;
    Result.Sl := LatestPass.HeadingChangePerDistance;
    Result.TurnAngle := SafeDesiredSteerAngle;
    Result.FinalHeading := LatestPass.TerminalPose.Angle;
    Result.CurveLength := LatestPass.Swtd;
    Result.PositionError := Abs(LatestPass.PErr);
    Result.HeadingError := Abs(LatestPass.HErr);
    Result.HeadingNormalAngle := NormalizePositiveAngle(LatestPass.TerminalPose.Angle + Pi / 2);
    Result.HeadingNormalError := Abs(LatestPass.HErr);
    Result.HeadingNormalSatisfied := IsFiniteDouble(LatestPass.HErr) and (Abs(LatestPass.HErr) <= 1e-5);
    Result.Vc := LatestPass.Vc;
    Result.TerminalPose := LatestPass.TerminalPose;
    Result.FinalPose := LatestPass.TerminalPose;
    Result.TerminalCoord.X := LatestPass.TerminalPose.X;
    Result.TerminalCoord.Y := LatestPass.TerminalPose.Y;
    Result.TerminalCoord.Psi := LatestPass.TerminalPose.Angle;
    Result.TerminalCoord.Length := 1;
    Result.TerminalCoord.LabelText := 'Rp';
    Result.TerminalCoord.Color := '#7dd3fc';
    SetLength(Result.PathPoints, 1);
    Result.PathPoints[0].X := LatestPass.TerminalPose.X;
    Result.PathPoints[0].Y := LatestPass.TerminalPose.Y;
    Result.PathPoints[0].Heading := LatestPass.TerminalPose.Angle;
    Result.PathPoints[0].SteerAngle := LatestPass.TerminalPose.SteerAngle;
  end;

  Result.Success := True;
  Result.EdgeCase := False;
  Result.EdgeCaseReason := '';
  Result.Radius := TargetRadius;
end;

end.
