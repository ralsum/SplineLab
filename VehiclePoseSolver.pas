unit VehiclePoseSolver;

interface

uses
  System.SysUtils,
  System.Math;

type
  TVehiclePose = record
    X: Double;
    Y: Double;
    Angle: Double;
    Theta: Double;
    Radius: Double;
    CurveLength: Double;
  end;

function SampleVehiclePoseForSlew(
  const BaseX, BaseY, BaseAngle, Distance, Slew, CurveLength, Radius: Double
): TVehiclePose;

function IntegrateVehiclePoseFrontForSlew(const Slew, Distance: Double): TVehiclePose;
function IntegrateVehiclePoseFallbackForSlew(const Slew, Distance: Double): TVehiclePose;

implementation

type
  TComplex = record
    Re: Double;
    Im: Double;
  end;

function IntegrateVehiclePoseFallbackForSlew(const Slew, Distance: Double): TVehiclePose; forward;

const
  QuadratureNodes: array[0..7] of Double = (
    -0.9602898564975363,
    -0.7966664774136267,
    -0.5255324099163290,
    -0.1834346424956498,
     0.1834346424956498,
     0.5255324099163290,
     0.7966664774136267,
     0.9602898564975363
  );

  QuadratureWeights: array[0..7] of Double = (
    0.10122853629037626,
    0.22238103445337448,
    0.31370664587788727,
    0.36268378337836196,
    0.36268378337836196,
    0.31370664587788727,
    0.22238103445337448,
    0.10122853629037626
  );

function ClampDouble(const Value, AMin, AMax: Double): Double;
begin
  Result := Value;
  if Result < AMin then
    Result := AMin
  else if Result > AMax then
    Result := AMax;
end;

function ComplexAdd(const A, B: TComplex): TComplex;
begin
  Result.Re := A.Re + B.Re;
  Result.Im := A.Im + B.Im;
end;

function ComplexScale(const A: TComplex; const Scale: Double): TComplex;
begin
  Result.Re := A.Re * Scale;
  Result.Im := A.Im * Scale;
end;

function ComplexMul(const A, B: TComplex): TComplex;
begin
  Result.Re := A.Re * B.Re - A.Im * B.Im;
  Result.Im := A.Re * B.Im + A.Im * B.Re;
end;

function ComplexExp(const Angle: Double): TComplex;
begin
  Result.Re := Cos(Angle);
  Result.Im := Sin(Angle);
end;

function PowMinusI(const Power: Integer): TComplex;
begin
  case ((Power mod 4) + 4) mod 4 of
    0:
      begin
        Result.Re := 1;
        Result.Im := 0;
      end;
    1:
      begin
        Result.Re := 0;
        Result.Im := -1;
      end;
    2:
      begin
        Result.Re := -1;
        Result.Im := 0;
      end;
  else
      begin
        Result.Re := 0;
        Result.Im := 1;
      end;
  end;
end;

function Factorial(const N: Integer): Double;
var
  I: Integer;
begin
  Result := 1.0;
  for I := 2 to N do
    Result := Result * I;
end;

function BesselJ(const Order: Integer; const X: Double): Double;
var
  N, M: Integer;
  Term, Sum, X2: Double;
begin
  N := Abs(Order);
  if X = 0 then
  begin
    if N = 0 then
      Exit(1.0);
    Exit(0.0);
  end;

  Term := Power(X / 2, N) / Factorial(N);
  Sum := Term;
  X2 := -(X * X) / 4;

  for M := 1 to 79 do
  begin
    Term := Term * X2 / (M * (M + N));
    Sum := Sum + Term;
    if Abs(Term) < Abs(Sum) * 1e-13 + 1e-15 then
      Break;
  end;

  Result := Sum;
  if (Order < 0) and Odd(N) then
    Result := -Result;
end;

function GetBesselTable(const Slew: Double; const Limit: Integer): TArray<Double>;
var
  Order: Integer;
begin
  SetLength(Result, Limit + 1);
  for Order := 0 to Limit do
    Result[Order] := BesselJ(Order, 1 / Slew);
end;

function IntegrateVehiclePoseFrontForSlew(const Slew, Distance: Double): TVehiclePose;
var
  InvSlew, Phase, Travel, PhaseSpan: Double;
  HarmonicLimit, M, BesselOrder: Integer;
  BesselValues: TArray<Double>;
  Integral, Harmonic, Term, BesselTermC: TComplex;
  BesselValue, BesselTerm: Double;
  BodyVector, LocalRear: TComplex;
begin
  if Slew = 0 then
  begin
    Result := IntegrateVehiclePoseFallbackForSlew(Slew, Distance);
    Exit;
  end;

  InvSlew := 1 / Slew;
  Phase := InvSlew;
  Travel := Distance;
  PhaseSpan := Slew * Travel;
  HarmonicLimit := Max(12, Ceil(Abs(InvSlew) + 24));
  BesselValues := GetBesselTable(Slew, HarmonicLimit + 1);
  Integral.Re := 0;
  Integral.Im := 0;

  for M := -HarmonicLimit to HarmonicLimit do
  begin
    BesselOrder := M - 1;
    BesselValue := BesselValues[Abs(BesselOrder)];
    if (BesselOrder < 0) and Odd(Abs(BesselOrder)) then
      BesselTerm := -BesselValue
    else
      BesselTerm := BesselValue;

    if M = 0 then
    begin
      Harmonic.Re := PhaseSpan;
      Harmonic.Im := 0;
    end
    else
    begin
      Harmonic.Re := Sin(M * PhaseSpan) / M;
      Harmonic.Im := (1 - Cos(M * PhaseSpan)) / M;
    end;

    BesselTermC.Re := BesselTerm;
    BesselTermC.Im := 0;
    Term := ComplexMul(ComplexMul(PowMinusI(M - 1), BesselTermC), Harmonic);
    Integral := ComplexAdd(Integral, Term);
  end;

  Integral := ComplexScale(Integral, 1 / Slew);
  Result := ComplexMul(ComplexExp(Phase), Integral);

  BodyVector := ComplexExp((2 * Sqr(Sin(PhaseSpan / 2))) / Slew);
  LocalRear.Re := 1 + Result.Re - BodyVector.Re;
  LocalRear.Im := Result.Im - BodyVector.Im;

  Result.Re := LocalRear.Re;
  Result.Im := LocalRear.Im;
end;

function IntegrateVehiclePoseFallbackForSlew(const Slew, Distance: Double): TVehiclePose;
var
  Travel, BodyDelta, HalfTravel, S, Phase: Double;
  I: Integer;
  FrontX, FrontY: Double;
begin
  Travel := Distance;
  if Slew = 0 then
    BodyDelta := 0
  else
    BodyDelta := (2 * Sqr(Sin((Slew * Travel) / 2))) / Slew;

  HalfTravel := Travel / 2;
  FrontX := 1;
  FrontY := 0;

  for I := Low(QuadratureNodes) to High(QuadratureNodes) do
  begin
    S := HalfTravel * (QuadratureNodes[I] + 1);
    if Slew = 0 then
      Phase := 0
    else
      Phase := Slew * S + (2 * Sqr(Sin((Slew * S) / 2))) / Slew;

    FrontX := FrontX + QuadratureWeights[I] * Cos(Phase) * HalfTravel;
    FrontY := FrontY + QuadratureWeights[I] * Sin(Phase) * HalfTravel;
  end;

  Result.X := FrontX - Cos(BodyDelta);
  Result.Y := FrontY - Sin(BodyDelta);
  Result.Angle := BodyDelta;
  Result.Theta := Slew * Travel;
  Result.Radius := 0;
  Result.CurveLength := 0;
end;

function SampleVehiclePoseForSlew(
  const BaseX, BaseY, BaseAngle, Distance, Slew, CurveLength, Radius: Double
): TVehiclePose;
var
  LocalPose: TVehiclePose;
  CosBase, SinBase: Double;
begin
  if Abs(Slew) < 0.001 then
    LocalPose := IntegrateVehiclePoseFallbackForSlew(Slew, Distance)
  else
    LocalPose := IntegrateVehiclePoseFrontForSlew(Slew, Distance);

  CosBase := Cos(BaseAngle);
  SinBase := Sin(BaseAngle);

  Result.X := BaseX + LocalPose.X * CosBase - LocalPose.Y * SinBase;
  Result.Y := BaseY + LocalPose.X * SinBase + LocalPose.Y * CosBase;
  Result.Angle := BaseAngle + LocalPose.Angle;
  Result.Theta := LocalPose.Theta;
  Result.Radius := Radius;
  Result.CurveLength := CurveLength;
end;

end.
