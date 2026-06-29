unit PoseSolver;

{$mode delphi}

interface

uses
  SysUtils,
  Math;

type
  TVehiclePose = record
    X: Double;
    Y: Double;
    Angle: Double;
    SteerAngle: Double;
    Radius: Double;
    CurveLength: Double;
  end;

  TBesselTable = array[0..511] of Double;

function MakeVehiclePose(
  const X, Y, Angle, SteerAngle, Radius, CurveLength: Double
): TVehiclePose;

function IntegrateVehiclePoseForSlew(const Distance, HeadingChangePerDistance: Double): TVehiclePose;
procedure InitializeBesselTables;

function SampleVehiclePoseForSlew(
  const BasePose: TVehiclePose;
  const Distance, HeadingChangePerDistance, CurveLength, Radius: Double
): TVehiclePose; overload;

function SampleVehiclePoseForSlew(
  const BaseX, BaseY, BaseAngle, Distance, HeadingChangePerDistance, CurveLength, Radius: Double
): TVehiclePose; overload;

function IntegrateVehiclePoseFrontForSlew(const Distance, HeadingChangePerDistance: Double): TVehiclePose;
function IntegrateVehiclePoseFallbackForSlew(const Distance, HeadingChangePerDistance: Double): TVehiclePose;

implementation

type
  TComplex = record
    Re: Double;
    Im: Double;
  end;

  TBesselTableEntry = record
    Slew: Double;
    Table: TBesselTable;
  end;

const
  SlewFallbackThreshold = 0.2;
  BesselTableMinSlew = 0.0001;
  BesselTableMaxSlew = 128.0;
  BesselTableStep = 0.01;
  BesselTableCount = Trunc((BesselTableMaxSlew - BesselTableMinSlew) / BesselTableStep) + 2;
  MaxBesselOrder = High(TBesselTable);

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

var
  BesselTables: array of TBesselTableEntry;
  BesselTablesReady: Boolean = False;
  LogFactorials: array[0..MaxBesselOrder] of Double;
  LogFactorialsReady: Boolean = False;

function ClampDouble(const Value, AMin, AMax: Double): Double;
begin
  Result := Value;
  if Result < AMin then
    Result := AMin
  else if Result > AMax then
    Result := AMax;
end;

function NonZeroDenominator(const Value: Double): Double;
begin
  if Abs(Value) < 1e-12 then
  begin
    if Value < 0 then
      Result := -1e-12
    else
      Result := 1e-12;
  end
  else
    Result := Value;
end;

function MakeVehiclePose(
  const X, Y, Angle, SteerAngle, Radius, CurveLength: Double
): TVehiclePose;
begin
  Result.X := X;
  Result.Y := Y;
  Result.Angle := Angle;
  Result.SteerAngle := SteerAngle;
  Result.Radius := Radius;
  Result.CurveLength := CurveLength;
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

procedure InitializeLogFactorials;
var
  I: Integer;
begin
  if LogFactorialsReady then
    Exit;

  LogFactorials[0] := 0;
  for I := 1 to High(LogFactorials) do
    LogFactorials[I] := LogFactorials[I - 1] + Ln(I);

  LogFactorialsReady := True;
end;

procedure ComputeBesselTable(
  const Slew: Double;
  const Limit: Integer;
  out Table: TBesselTable
); forward;

function QuadraticInterpolate(
  const X0, Y0, X1, Y1, X2, Y2, X: Double
): Double;
var
  L0, L1, L2: Double;
begin
  L0 := ((X - X1) * (X - X2)) / ((X0 - X1) * (X0 - X2));
  L1 := ((X - X0) * (X - X2)) / ((X1 - X0) * (X1 - X2));
  L2 := ((X - X0) * (X - X1)) / ((X2 - X0) * (X2 - X1));
  Result := Y0 * L0 + Y1 * L1 + Y2 * L2;
end;

function BesselTableSlewAt(const Index: Integer): Double;
begin
  Result := Min(BesselTableMaxSlew, BesselTableMinSlew + Index * BesselTableStep);
end;

procedure InitializeBesselTables;
var
  Index: Integer;
begin
  if BesselTablesReady then
    Exit;

  SetLength(BesselTables, BesselTableCount);
  for Index := 0 to High(BesselTables) do
  begin
    BesselTables[Index].Slew := BesselTableSlewAt(Index);
    ComputeBesselTable(BesselTables[Index].Slew, MaxBesselOrder, BesselTables[Index].Table);
  end;

  BesselTablesReady := True;
end;

function TryGetBesselTableFromGrid(
  const Slew: Double;
  out Table: TBesselTable
): Boolean;
var
  LowerIndex, UpperIndex, MidIndex, Order, TableCount: Integer;
  LowerSlew, MidSlew, UpperSlew: Double;
  LowerTable, MidTable, UpperTable: TBesselTable;
begin
  Result := False;
  if not BesselTablesReady then
    InitializeBesselTables;

  TableCount := Length(BesselTables);
  if TableCount = 0 then
    Exit(False);

  if Slew <= BesselTables[0].Slew then
  begin
    Table := BesselTables[0].Table;
    Exit(True);
  end;

  if Slew >= BesselTables[TableCount - 1].Slew then
  begin
    Table := BesselTables[TableCount - 1].Table;
    Exit(True);
  end;

  LowerIndex := 0;
  UpperIndex := TableCount - 1;
  while LowerIndex + 1 < UpperIndex do
  begin
    MidIndex := (LowerIndex + UpperIndex) div 2;
    if BesselTables[MidIndex].Slew <= Slew then
      LowerIndex := MidIndex
    else
      UpperIndex := MidIndex;
  end;

  if LowerIndex = 0 then
  begin
    MidIndex := 1;
    UpperIndex := 2;
  end
  else if LowerIndex >= TableCount - 2 then
  begin
    MidIndex := TableCount - 2;
    LowerIndex := TableCount - 3;
    UpperIndex := TableCount - 1;
  end
  else
  begin
    MidIndex := LowerIndex;
    LowerIndex := LowerIndex - 1;
  end;

  LowerSlew := BesselTables[LowerIndex].Slew;
  MidSlew := BesselTables[MidIndex].Slew;
  UpperSlew := BesselTables[UpperIndex].Slew;
  LowerTable := BesselTables[LowerIndex].Table;
  MidTable := BesselTables[MidIndex].Table;
  UpperTable := BesselTables[UpperIndex].Table;

  for Order := Low(TBesselTable) to High(TBesselTable) do
    Table[Order] := QuadraticInterpolate(
      LowerSlew, LowerTable[Order],
      MidSlew, MidTable[Order],
      UpperSlew, UpperTable[Order],
      Slew
    );

  Result := True;
end;

function BesselJ(const Order: Integer; const X: Double): Double;
var
  N, M: Integer;
  Term, Sum, X2: Double;
  Converged: Boolean;
  LogTerm: Double;
const
  BesselSeriesUnderflowThreshold = -745.0;
  BesselTinyTermThreshold = 1e-300;
begin
  if not LogFactorialsReady then
    InitializeLogFactorials;

  N := Abs(Order);
  if X = 0 then
  begin
    if N = 0 then
      Result := 1.0
    else
      Result := 0.0;
  end
  else if Abs(X) > 30 then
  begin
    Result := Sqrt(2 / NonZeroDenominator(Pi * Abs(X))) * Cos(Abs(X) - (N * Pi / 2) - (Pi / 4));
    if (Order < 0) and Odd(N) then
      Result := -Result;
  end
  else
  begin
    LogTerm := N * Ln(Abs(X) / 2) - LogFactorials[N];
    if LogTerm < BesselSeriesUnderflowThreshold then
    begin
      Result := 0.0;
      if (Order < 0) and Odd(N) then
        Result := -Result;
      Exit;
    end;

    Term := Exp(LogTerm);
    Sum := Term;
    X2 := -(X * X) / 4;
    Converged := False;

    for M := 1 to 79 do
    begin
      if not Converged then
      begin
        if Abs(Term) < BesselTinyTermThreshold then
          Break;

        Term := Term * X2 / (M * (M + N));
        Sum := Sum + Term;
        if Abs(Term) < Abs(Sum) * 1e-13 + 1e-15 then
          Converged := True;
      end;
    end;

    Result := Sum;
    if (Order < 0) and Odd(N) then
      Result := -Result;
  end;
end;

procedure ComputeBesselTable(
  const Slew: Double;
  const Limit: Integer;
  out Table: TBesselTable
);
var
  Order, ClampedLimit: Integer;
begin
  ClampedLimit := Round(ClampDouble(Limit, 0, MaxBesselOrder));
  for Order := 0 to ClampedLimit do
    Table[Order] := BesselJ(Order, 1 / NonZeroDenominator(Slew));
end;

procedure BuildBesselTable(
  const Slew: Double;
  const Limit: Integer;
  out Table: TBesselTable
);
begin
  TryGetBesselTableFromGrid(Slew, Table);
end;

function IntegrateVehiclePoseFrontForSlew(const Distance, HeadingChangePerDistance: Double): TVehiclePose;
var
  SafeSlew, InvSlew, Phase, Travel, PhaseSpan, HeadingChange: Double;
  HarmonicLimit, M, BesselOrder: Integer;
  BesselValues: TBesselTable;
  Integral, Harmonic, Term, BesselTermC, FrontVector: TComplex;
  BesselValue, BesselTerm: Double;
  BodyVector, LocalRear: TComplex;
begin
  if Abs(Distance) < 1e-12 then
    Exit(MakeVehiclePose(0, 0, 0, 0, 0, 0));

  SafeSlew := HeadingChangePerDistance;
  if Abs(SafeSlew) < SlewFallbackThreshold then
    Result := IntegrateVehiclePoseFallbackForSlew(Distance, HeadingChangePerDistance)
  else
  begin
    SafeSlew := NonZeroDenominator(SafeSlew);
    InvSlew := 1 / SafeSlew;
    Phase := InvSlew;
    Travel := Distance;
    HeadingChange := SafeSlew * Distance;
    PhaseSpan := HeadingChange;
    HarmonicLimit := Max(12, Ceil(Abs(InvSlew) + 24));
    HarmonicLimit := Round(ClampDouble(HarmonicLimit, 12, MaxBesselOrder - 1));
    BuildBesselTable(SafeSlew, HarmonicLimit + 1, BesselValues);
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

    Integral := ComplexScale(Integral, 1 / SafeSlew);
    FrontVector := ComplexMul(ComplexExp(Phase), Integral);

    BodyVector := ComplexExp((2 * Sqr(Sin(PhaseSpan / 2))) / SafeSlew);
    LocalRear.Re := 1 + FrontVector.Re - BodyVector.Re;
    LocalRear.Im := FrontVector.Im - BodyVector.Im;

    Result.X := LocalRear.Re;
    Result.Y := LocalRear.Im;
    Result.Angle := (2 * Sqr(Sin(PhaseSpan / 2))) / SafeSlew;
    Result.SteerAngle := HeadingChange;
    Result.Radius := 0;
    Result.CurveLength := 0;
  end;
end;

function IntegrateVehiclePoseFallbackForSlew(const Distance, HeadingChangePerDistance: Double): TVehiclePose;
var
  Travel, Slew, HeadingChange, BodyDelta, HalfTravel, S, Phase: Double;
  I: Integer;
  FrontX, FrontY: Double;
begin
  Travel := Distance;
  if Abs(Distance) < 1e-12 then
  begin
    Result := MakeVehiclePose(0, 0, 0, 0, 0, 0);
    Exit;
  end;

  Slew := HeadingChangePerDistance;
  HeadingChange := Slew * Distance;
  BodyDelta := (2 * Sqr(Sin(HeadingChange / 2))) / NonZeroDenominator(Slew);

  HalfTravel := Travel / 2;
  FrontX := 1;
  FrontY := 0;

  for I := Low(QuadratureNodes) to High(QuadratureNodes) do
  begin
    S := HalfTravel * (QuadratureNodes[I] + 1);
    Phase := Slew * S + (2 * Sqr(Sin((HeadingChange * S) / (2 * Distance)))) / NonZeroDenominator(Slew);

    FrontX := FrontX + QuadratureWeights[I] * Cos(Phase) * HalfTravel;
    FrontY := FrontY + QuadratureWeights[I] * Sin(Phase) * HalfTravel;
  end;

  Result.X := FrontX - Cos(BodyDelta);
  Result.Y := FrontY - Sin(BodyDelta);
  Result.Angle := BodyDelta;
  Result.SteerAngle := HeadingChange;
  Result.Radius := 0;
  Result.CurveLength := 0;
end;

function IntegrateVehiclePoseForSlew(const Distance, HeadingChangePerDistance: Double): TVehiclePose;
begin
  // Small heading-change-per-distance values are numerically safer with the quadrature path.
  if Abs(Distance) < 1e-12 then
    Result := MakeVehiclePose(0, 0, 0, 0, 0, 0)
  else if Abs(HeadingChangePerDistance) < SlewFallbackThreshold then
    Result := IntegrateVehiclePoseFallbackForSlew(Distance, HeadingChangePerDistance)
  else
    Result := IntegrateVehiclePoseFrontForSlew(Distance, HeadingChangePerDistance);
end;

function SampleVehiclePoseForSlew(
  const BasePose: TVehiclePose;
  const Distance, HeadingChangePerDistance, CurveLength, Radius: Double
): TVehiclePose;
begin
  Result := SampleVehiclePoseForSlew(
    BasePose.X,
    BasePose.Y,
    BasePose.Angle,
    Distance,
    HeadingChangePerDistance,
    CurveLength,
    Radius
  );
end;

function SampleVehiclePoseForSlew(
  const BaseX, BaseY, BaseAngle, Distance, HeadingChangePerDistance, CurveLength, Radius: Double
): TVehiclePose;
var
  LocalPose: TVehiclePose;
  CosBase, SinBase: Double;
begin
  LocalPose := IntegrateVehiclePoseForSlew(Distance, HeadingChangePerDistance);

  CosBase := Cos(BaseAngle);
  SinBase := Sin(BaseAngle);

  Result := MakeVehiclePose(
    BaseX + LocalPose.X * CosBase - LocalPose.Y * SinBase,
    BaseY + LocalPose.X * SinBase + LocalPose.Y * CosBase,
    BaseAngle + LocalPose.Angle,
    LocalPose.SteerAngle,
    Radius,
    CurveLength
  );
end;

initialization
  InitializeLogFactorials;
  InitializeBesselTables;

end.
