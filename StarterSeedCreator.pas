unit StarterSeedCreator;

{$mode delphi}

interface

uses
  SysUtils,
  Math;

type
  TDoubleArray = array of Double;

  TStarterSeedCell = record
    StepIndex: Integer;
    RadiusIndex: Integer;
    Radius: Double;
    RadiusAxisValue: Double;
    RawPsiDegrees: Double;
    Swtd: Double;
    DesStrAng: Double;
    Source: string;
    Confidence: Double;
  end;

  TStarterSeedRow = array of TStarterSeedCell;
  TStarterSeedGrid = array of TStarterSeedRow;

function StarterSeedRadiusAxis: TDoubleArray;
function StarterSeedRawPsiAxis: TDoubleArray;
function BuildStarterSeedGrid: TStarterSeedGrid;
function BuildStarterSeedCandidates(const Radius, RawPsiDegrees: Double): TStarterSeedRow;
function GetStarterSeedForRequest(const Radius, RawPsiDegrees: Double): TStarterSeedCell;

implementation

const
  StarterSeedFixedRadius = 1.0;
  StarterSeedRawPsiMinDegrees = 0.0;
  StarterSeedRawPsiMaxDegrees = 90.0;
  StarterSeedRawPsiStepDegrees = 5.0;
  StarterSeedBootstrapSwtd = 1.286640028;
  StarterSeedBootstrapDesStrAng = 1.464667296;
  StarterSeedSwtdTerminalScale = 0.93;
  StarterSeedDesStrAngBaseScale = 0.92;
  StarterSeedRadiusExponent = 0.35;
  StarterSeedRadiusScaleMin = 0.5;
  StarterSeedRadiusScaleMax = 3.0;
  StarterSeedDesStrAngScaleMin = 0.84;
  StarterSeedDesStrAngScaleMax = 1.08;
  StarterSeedMinConfidence = 0.35;
  StarterSeedMaxConfidence = 1.0;

function ClampDouble(const Value, AMin, AMax: Double): Double;
begin
  Result := Value;
  if Result < AMin then
    Result := AMin
  else if Result > AMax then
    Result := AMax;
end;

function LimitSwtdMinimum(const Value: Double): Double;
begin
  if IsNan(Value) or (Abs(Value) > 1.0E300) or (Value < 1e-6) then
    Result := 1e-6
  else
    Result := Value;
end;

function IsFiniteDouble(const Value: Double): Boolean;
begin
  Result := (not IsNan(Value)) and (Abs(Value) < 1.0E300);
end;

function BuildLinearAxis(const MinValue, MaxValue, StepValue: Double): TDoubleArray;
var
  TotalSteps, Index: Integer;
  Value: Double;
begin
  TotalSteps := Round((MaxValue - MinValue) / StepValue);
  SetLength(Result, TotalSteps + 1);
  for Index := 0 to TotalSteps do
  begin
    Value := MinValue + (Index * StepValue);
    Result[Index] := Value;
  end;
end;

function StarterSeedRadiusAxis: TDoubleArray;
var
  Index: Integer;
begin
  Result := BuildLinearAxis(-4.8, 7.2, 0.2);
  for Index := Low(Result) to High(Result) do
    Result[Index] := Power(10, Result[Index]);
end;

function StarterSeedRawPsiAxis: TDoubleArray;
begin
  Result := BuildLinearAxis(StarterSeedRawPsiMinDegrees, StarterSeedRawPsiMaxDegrees, StarterSeedRawPsiStepDegrees);
end;

function GetRadiusAxisValue(const Radius: Double): Double;
begin
  Result := Abs(Radius);
  if Result <= 0 then
    Result := StarterSeedFixedRadius;
end;

function GetNearestRadiusIndex(const Radius: Double): Integer;
var
  Axis: TDoubleArray;
  Index: Integer;
  Distance, BestDistance: Double;
begin
  Axis := StarterSeedRadiusAxis;
  Result := 0;
  BestDistance := MaxDouble;
  for Index := Low(Axis) to High(Axis) do
  begin
    Distance := Abs(Axis[Index] - GetRadiusAxisValue(Radius));
    if Distance < BestDistance then
    begin
      BestDistance := Distance;
      Result := Index;
    end;
  end;
end;

function GetBoundingAxisIndices(const Axis: TDoubleArray; const Value: Double; out LowerIndex, UpperIndex: Integer; out Mix: Double): Boolean;
var
  Index, LastIndex: Integer;
  Span: Double;
begin
  Result := False;
  LowerIndex := 0;
  UpperIndex := 0;
  Mix := 0;
  if Length(Axis) = 0 then
    Exit;
  if Value <= Axis[Low(Axis)] then
  begin
    Result := True;
    Exit;
  end;
  LastIndex := High(Axis);
  if Value >= Axis[LastIndex] then
  begin
    LowerIndex := LastIndex;
    UpperIndex := LastIndex;
    Result := True;
    Exit;
  end;
  for Index := Low(Axis) to LastIndex - 1 do
  begin
    if (Value >= Axis[Index]) and (Value <= Axis[Index + 1]) then
    begin
      LowerIndex := Index;
      UpperIndex := Index + 1;
      Span := Axis[Index + 1] - Axis[Index];
      if Abs(Span) > 1e-12 then
        Mix := ClampDouble((Value - Axis[Index]) / Span, 0, 1)
      else
        Mix := 0;
      Result := True;
      Exit;
    end;
  end;
end;

function SmoothStep(const T: Double): Double;
begin
  Result := T * T * (3 - (2 * T));
end;

function BuildPriorProfileSeed(const RawPsiDegrees, RadiusValue: Double; const Previous: TStarterSeedCell): TStarterSeedCell;
var
  Normalized, Eased, RadiusScale, DesScale: Double;
begin
  Normalized := ClampDouble((StarterSeedRawPsiMaxDegrees - RawPsiDegrees)
    / Max(1e-9, StarterSeedRawPsiMaxDegrees - StarterSeedRawPsiMinDegrees), 0, 1);
  Eased := SmoothStep(Normalized);
  RadiusScale := ClampDouble(Power(Max(1e-6, Abs(RadiusValue) / StarterSeedFixedRadius), StarterSeedRadiusExponent),
    StarterSeedRadiusScaleMin, StarterSeedRadiusScaleMax);
  DesScale := ClampDouble(StarterSeedDesStrAngBaseScale + ((RadiusScale - 1) * 0.06),
    StarterSeedDesStrAngScaleMin, StarterSeedDesStrAngScaleMax);
  Result.StepIndex := Previous.StepIndex + 1;
  Result.RadiusIndex := Previous.RadiusIndex;
  Result.Radius := RadiusValue;
  Result.RadiusAxisValue := RadiusValue;
  Result.RawPsiDegrees := RawPsiDegrees;
  Result.Swtd := LimitSwtdMinimum(StarterSeedBootstrapSwtd + ((StarterSeedBootstrapSwtd * StarterSeedSwtdTerminalScale * RadiusScale - StarterSeedBootstrapSwtd) * Eased));
  Result.DesStrAng := ClampDouble(StarterSeedBootstrapDesStrAng + ((StarterSeedBootstrapDesStrAng * DesScale - StarterSeedBootstrapDesStrAng) * Eased), 0, Pi / 2);
  Result.Source := 'prior-profile';
  Result.Confidence := 0.45;
end;

function ClampStarterSeedValues(const Seed, Previous: TStarterSeedCell): TStarterSeedCell;
var
  PriorSwtd, PriorDesStrAng, TargetSwtd, TargetDesStrAng, SwtdFloor, SwtdCeil, DesStrAngDelta: Double;
  LowerBound, UpperBound: Double;
begin
  PriorSwtd := Previous.Swtd;
  PriorDesStrAng := Previous.DesStrAng;
  TargetSwtd := Seed.Swtd;
  TargetDesStrAng := Seed.DesStrAng;
  if (PriorSwtd > 0) and IsFiniteDouble(PriorSwtd) then
  begin
    SwtdFloor := PriorSwtd * 0.7;
    SwtdCeil := PriorSwtd * 1.4;
  end
  else
  begin
    SwtdFloor := 1e-6;
    SwtdCeil := MaxDouble;
  end;
  if IsFiniteDouble(PriorDesStrAng) then
    DesStrAngDelta := Max(Pi / 36, Abs(PriorDesStrAng) * 0.25)
  else
    DesStrAngDelta := MaxDouble;
  Result := Seed;
  if IsFiniteDouble(TargetSwtd) then
    Result.Swtd := LimitSwtdMinimum(ClampDouble(TargetSwtd, SwtdFloor, SwtdCeil))
  else
    Result.Swtd := LimitSwtdMinimum(PriorSwtd);
  if IsFiniteDouble(TargetDesStrAng) then
  begin
    if IsFiniteDouble(PriorDesStrAng) then
    begin
      LowerBound := PriorDesStrAng - DesStrAngDelta;
      UpperBound := PriorDesStrAng + DesStrAngDelta;
    end
    else
    begin
      LowerBound := 0;
      UpperBound := Pi / 2;
    end;
    Result.DesStrAng := ClampDouble(TargetDesStrAng, LowerBound, UpperBound);
  end
  else
    Result.DesStrAng := PriorDesStrAng;
  Result.DesStrAng := ClampDouble(Result.DesStrAng, 0, Pi / 2);
end;

function SeedsEquivalent(const Left, Right: TStarterSeedCell): Boolean;
begin
  Result := (Abs(Left.Radius - Right.Radius) < 1e-12)
    and (Abs(Left.RawPsiDegrees - Right.RawPsiDegrees) < 1e-12)
    and (Abs(Left.Swtd - Right.Swtd) < 1e-12)
    and (Abs(Left.DesStrAng - Right.DesStrAng) < 1e-12);
end;

function BlendStarterSeedCells(
  const Left, Right: TStarterSeedCell;
  const Mix: Double;
  const Source: string;
  const Confidence: Double
): TStarterSeedCell;
var
  ClampedMix: Double;
begin
  ClampedMix := ClampDouble(Mix, 0, 1);
  Result := Left;
  Result.StepIndex := Round(Left.StepIndex + ((Right.StepIndex - Left.StepIndex) * ClampedMix));
  Result.RadiusIndex := Round(Left.RadiusIndex + ((Right.RadiusIndex - Left.RadiusIndex) * ClampedMix));
  Result.Radius := Left.Radius + ((Right.Radius - Left.Radius) * ClampedMix);
  Result.RadiusAxisValue := Left.RadiusAxisValue + ((Right.RadiusAxisValue - Left.RadiusAxisValue) * ClampedMix);
  Result.RawPsiDegrees := Left.RawPsiDegrees + ((Right.RawPsiDegrees - Left.RawPsiDegrees) * ClampedMix);
  Result.Swtd := LimitSwtdMinimum(Left.Swtd + ((Right.Swtd - Left.Swtd) * ClampedMix));
  Result.DesStrAng := ClampDouble(Left.DesStrAng + ((Right.DesStrAng - Left.DesStrAng) * ClampedMix), 0, Pi / 2);
  Result.Source := Source;
  Result.Confidence := Confidence;
end;

function PerturbStarterSeed(
  const Seed: TStarterSeedCell;
  const SwtdScale, DesStrAngDelta: Double;
  const Source: string;
  const Confidence: Double
): TStarterSeedCell;
begin
  Result := Seed;
  Result.Swtd := LimitSwtdMinimum(Seed.Swtd * SwtdScale);
  Result.DesStrAng := ClampDouble(Seed.DesStrAng + DesStrAngDelta, 0, Pi / 2);
  Result.Source := Source;
  Result.Confidence := Confidence;
end;

function InterpolateSeedValue(
  const C00, C10, C01, C11: TStarterSeedCell;
  const RadiusMix, PsiMix: Double;
  const Key: string
): Double; forward;

function GetGridCell(const Grid: TStarterSeedGrid; const RadiusIndex, StepIndex: Integer): TStarterSeedCell; forward;

function GetStarterSeedForGridRequest(const Grid: TStarterSeedGrid; const Radius, RawPsiDegrees: Double): TStarterSeedCell;
var
  RadiusAxis, RawPsiAxis: TDoubleArray;
  RadiusLower, RadiusUpper, PsiLower, PsiUpper: Integer;
  RadiusMix, PsiMix: Double;
  RadiusValue: Double;
  C00, C10, C01, C11: TStarterSeedCell;
begin
  RadiusAxis := StarterSeedRadiusAxis;
  RawPsiAxis := StarterSeedRawPsiAxis;
  RadiusValue := GetRadiusAxisValue(Radius);
  if RadiusValue <= 0 then
    RadiusValue := StarterSeedFixedRadius;
  GetBoundingAxisIndices(RadiusAxis, RadiusValue, RadiusLower, RadiusUpper, RadiusMix);
  GetBoundingAxisIndices(RawPsiAxis, RawPsiDegrees, PsiLower, PsiUpper, PsiMix);
  C00 := GetGridCell(Grid, RadiusLower, PsiLower);
  C10 := GetGridCell(Grid, RadiusUpper, PsiLower);
  C01 := GetGridCell(Grid, RadiusLower, PsiUpper);
  C11 := GetGridCell(Grid, RadiusUpper, PsiUpper);
  if (RadiusLower = RadiusUpper) and (PsiLower = PsiUpper) and (C00.StepIndex >= 0) then
  begin
    Result := C00;
    Result.Radius := RadiusValue;
    Result.RawPsiDegrees := RawPsiDegrees;
    Exit;
  end;
  Result := C00;
  Result.StepIndex := PsiLower;
  Result.RadiusIndex := RadiusLower;
  Result.Radius := RadiusValue;
  Result.RadiusAxisValue := RadiusAxis[RadiusLower];
  Result.RawPsiDegrees := RawPsiDegrees;
  Result.Swtd := LimitSwtdMinimum(InterpolateSeedValue(C00, C10, C01, C11, RadiusMix, PsiMix, 'swtd'));
  Result.DesStrAng := ClampDouble(InterpolateSeedValue(C00, C10, C01, C11, RadiusMix, PsiMix, 'desStrAng'), 0, Pi / 2);
  Result.Source := 'grid-bilinear';
  Result.Confidence := 0.8;
end;

function BuildStarterSeedGrid: TStarterSeedGrid;
  var
    RadiusAxis, RawPsiAxis: TDoubleArray;
    RadiusIndex, PsiIndex: Integer;
    RadiusValue: Double;
    Row: TStarterSeedRow;
    PreviousSeed, Seed: TStarterSeedCell;
    FixedRadiusIndex: Integer;
begin
  RadiusAxis := StarterSeedRadiusAxis;
  RawPsiAxis := StarterSeedRawPsiAxis;
  SetLength(Result, Length(RadiusAxis));
  FixedRadiusIndex := GetNearestRadiusIndex(StarterSeedFixedRadius);
  for RadiusIndex := Low(RadiusAxis) to High(RadiusAxis) do
  begin
    RadiusValue := RadiusAxis[RadiusIndex];
    SetLength(Row, Length(RawPsiAxis));
    PreviousSeed.StepIndex := -1;
    PreviousSeed.RadiusIndex := RadiusIndex;
    PreviousSeed.Radius := RadiusValue;
    PreviousSeed.RadiusAxisValue := RadiusValue;
    PreviousSeed.RawPsiDegrees := StarterSeedRawPsiMaxDegrees;
    PreviousSeed.Swtd := StarterSeedBootstrapSwtd;
    PreviousSeed.DesStrAng := StarterSeedBootstrapDesStrAng;
    PreviousSeed.Source := 'bootstrap';
    PreviousSeed.Confidence := 1;
    for PsiIndex := Low(RawPsiAxis) to High(RawPsiAxis) do
    begin
      if (RadiusIndex = FixedRadiusIndex) and (Abs(RawPsiAxis[PsiIndex] - StarterSeedRawPsiMaxDegrees) < 1e-12) then
      begin
        Seed.StepIndex := PsiIndex;
        Seed.RadiusIndex := RadiusIndex;
        Seed.Radius := RadiusValue;
        Seed.RadiusAxisValue := RadiusValue;
        Seed.RawPsiDegrees := RawPsiAxis[PsiIndex];
        Seed.Swtd := StarterSeedBootstrapSwtd;
        Seed.DesStrAng := StarterSeedBootstrapDesStrAng;
        Seed.Source := 'bootstrap';
        Seed.Confidence := 1;
      end
      else
      begin
        Seed := BuildPriorProfileSeed(RawPsiAxis[PsiIndex], RadiusValue, PreviousSeed);
        Seed.StepIndex := PsiIndex;
        Seed.RadiusIndex := RadiusIndex;
        Seed.Radius := RadiusValue;
        Seed.RadiusAxisValue := RadiusValue;
      end;
      Seed := ClampStarterSeedValues(Seed, PreviousSeed);
      Row[PsiIndex] := Seed;
      PreviousSeed := Seed;
    end;
    Result[RadiusIndex] := Row;
  end;
end;

function InterpolateSeedValue(
  const C00, C10, C01, C11: TStarterSeedCell;
  const RadiusMix, PsiMix: Double;
  const Key: string
): Double;
var
  V00, V10, V01, V11: Double;
  WeightedSum, WeightSum: Double;
begin
  if SameText(Key, 'swtd') then
  begin
    V00 := C00.Swtd;
    V10 := C10.Swtd;
    V01 := C01.Swtd;
    V11 := C11.Swtd;
  end
  else
  begin
    V00 := C00.DesStrAng;
    V10 := C10.DesStrAng;
    V01 := C01.DesStrAng;
    V11 := C11.DesStrAng;
  end;
  if IsFiniteDouble(V00) and IsFiniteDouble(V10) and IsFiniteDouble(V01) and IsFiniteDouble(V11) then
  begin
    Result := ((1 - RadiusMix) * (1 - PsiMix) * V00)
      + (RadiusMix * (1 - PsiMix) * V10)
      + ((1 - RadiusMix) * PsiMix * V01)
      + (RadiusMix * PsiMix * V11);
    Exit;
  end;
  WeightedSum := 0;
  WeightSum := 0;
  if IsFiniteDouble(V00) then begin WeightedSum := WeightedSum + V00 * ((1 - RadiusMix) * (1 - PsiMix)); WeightSum := WeightSum + ((1 - RadiusMix) * (1 - PsiMix)); end;
  if IsFiniteDouble(V10) then begin WeightedSum := WeightedSum + V10 * (RadiusMix * (1 - PsiMix)); WeightSum := WeightSum + (RadiusMix * (1 - PsiMix)); end;
  if IsFiniteDouble(V01) then begin WeightedSum := WeightedSum + V01 * ((1 - RadiusMix) * PsiMix); WeightSum := WeightSum + ((1 - RadiusMix) * PsiMix); end;
  if IsFiniteDouble(V11) then begin WeightedSum := WeightedSum + V11 * (RadiusMix * PsiMix); WeightSum := WeightSum + (RadiusMix * PsiMix); end;
  if WeightSum > 0 then
    Result := WeightedSum / WeightSum
  else
    Result := NaN;
end;

function GetGridCell(const Grid: TStarterSeedGrid; const RadiusIndex, StepIndex: Integer): TStarterSeedCell;
begin
  Result.StepIndex := -1;
  if (RadiusIndex >= Low(Grid)) and (RadiusIndex <= High(Grid)) and
     (StepIndex >= Low(Grid[RadiusIndex])) and (StepIndex <= High(Grid[RadiusIndex])) then
    Result := Grid[RadiusIndex][StepIndex];
end;

function GetStarterSeedForRequest(const Radius, RawPsiDegrees: Double): TStarterSeedCell;
var
  Grid: TStarterSeedGrid;
begin
  Grid := BuildStarterSeedGrid;
  Result := GetStarterSeedForGridRequest(Grid, Radius, RawPsiDegrees);
end;

function BuildStarterSeedCandidates(const Radius, RawPsiDegrees: Double): TStarterSeedRow;
var
  Grid: TStarterSeedGrid;
  RadiusAxis, RawPsiAxis: TDoubleArray;
  RadiusLower, RadiusUpper, PsiLower, PsiUpper: Integer;
  RadiusMix, PsiMix: Double;
  RadiusValue: Double;
  BaseSeed, PriorSeed, Candidate: TStarterSeedCell;
  Count: Integer;
  PsiJitter: Double;

  procedure AppendUniqueCandidate(const Seed: TStarterSeedCell);
  var
    Index: Integer;
  begin
    for Index := 0 to Count - 1 do
    begin
      if SeedsEquivalent(Result[Index], Seed) then
        Exit;
    end;
    SetLength(Result, Count + 1);
    Result[Count] := Seed;
    Inc(Count);
  end;

begin
  Grid := BuildStarterSeedGrid;
  RadiusAxis := StarterSeedRadiusAxis;
  RawPsiAxis := StarterSeedRawPsiAxis;
  RadiusValue := GetRadiusAxisValue(Radius);
  GetBoundingAxisIndices(RadiusAxis, RadiusValue, RadiusLower, RadiusUpper, RadiusMix);
  GetBoundingAxisIndices(RawPsiAxis, RawPsiDegrees, PsiLower, PsiUpper, PsiMix);

  SetLength(Result, 0);
  Count := 0;

  BaseSeed := GetStarterSeedForGridRequest(Grid, RadiusValue, RawPsiDegrees);
  BaseSeed.Source := 'starter-bilinear';
  BaseSeed.Confidence := 1.0;
  AppendUniqueCandidate(BaseSeed);

  PsiJitter := Max(Pi / 360, Abs(BaseSeed.DesStrAng) * 0.01);
  Candidate := PerturbStarterSeed(BaseSeed, 0.995, 0, 'starter-bilinear-fine-swtd-low', 0.98);
  AppendUniqueCandidate(Candidate);

  Candidate := PerturbStarterSeed(BaseSeed, 1.005, 0, 'starter-bilinear-fine-swtd-high', 0.975);
  AppendUniqueCandidate(Candidate);

  Candidate := PerturbStarterSeed(BaseSeed, 1.0, -PsiJitter, 'starter-bilinear-fine-des-low', 0.97);
  AppendUniqueCandidate(Candidate);

  Candidate := PerturbStarterSeed(BaseSeed, 1.0, PsiJitter, 'starter-bilinear-fine-des-high', 0.965);
  AppendUniqueCandidate(Candidate);

  Candidate := PerturbStarterSeed(BaseSeed, 0.9975, -PsiJitter * 0.5, 'starter-bilinear-fine-diagonal-low', 0.96);
  AppendUniqueCandidate(Candidate);

  Candidate := PerturbStarterSeed(BaseSeed, 1.0025, PsiJitter * 0.5, 'starter-bilinear-fine-diagonal-high', 0.955);
  AppendUniqueCandidate(Candidate);

  if (GetGridCell(Grid, RadiusLower, PsiLower).StepIndex >= 0) and (GetGridCell(Grid, RadiusUpper, PsiLower).StepIndex >= 0) then
  begin
    Candidate := BlendStarterSeedCells(
      GetGridCell(Grid, RadiusLower, PsiLower),
      GetGridCell(Grid, RadiusUpper, PsiLower),
      RadiusMix,
      'starter-radius-lower-row',
      0.97
    );
    AppendUniqueCandidate(Candidate);
  end;

  if (GetGridCell(Grid, RadiusLower, PsiUpper).StepIndex >= 0) and (GetGridCell(Grid, RadiusUpper, PsiUpper).StepIndex >= 0) then
  begin
    Candidate := BlendStarterSeedCells(
      GetGridCell(Grid, RadiusLower, PsiUpper),
      GetGridCell(Grid, RadiusUpper, PsiUpper),
      RadiusMix,
      'starter-radius-upper-row',
      0.96
    );
    AppendUniqueCandidate(Candidate);
  end;

  if (GetGridCell(Grid, RadiusLower, PsiLower).StepIndex >= 0) and (GetGridCell(Grid, RadiusLower, PsiUpper).StepIndex >= 0) then
  begin
    Candidate := BlendStarterSeedCells(
      GetGridCell(Grid, RadiusLower, PsiLower),
      GetGridCell(Grid, RadiusLower, PsiUpper),
      PsiMix,
      'starter-psi-lower-column',
      0.95
    );
    AppendUniqueCandidate(Candidate);
  end;

  if (GetGridCell(Grid, RadiusUpper, PsiLower).StepIndex >= 0) and (GetGridCell(Grid, RadiusUpper, PsiUpper).StepIndex >= 0) then
  begin
    Candidate := BlendStarterSeedCells(
      GetGridCell(Grid, RadiusUpper, PsiLower),
      GetGridCell(Grid, RadiusUpper, PsiUpper),
      PsiMix,
      'starter-psi-upper-column',
      0.94
    );
    AppendUniqueCandidate(Candidate);
  end;

  if RadiusMix <= 0.5 then
  begin
    if PsiMix <= 0.5 then
    begin
      Candidate := GetGridCell(Grid, RadiusLower, PsiLower);
      Candidate.Source := 'starter-corner-lower-lower';
      Candidate.Confidence := 0.95;
      AppendUniqueCandidate(Candidate);

      Candidate := GetGridCell(Grid, RadiusLower, PsiUpper);
      Candidate.Source := 'starter-corner-lower-upper';
      Candidate.Confidence := 0.94;
      AppendUniqueCandidate(Candidate);

      Candidate := GetGridCell(Grid, RadiusUpper, PsiLower);
      Candidate.Source := 'starter-corner-upper-lower';
      Candidate.Confidence := 0.93;
      AppendUniqueCandidate(Candidate);

      Candidate := GetGridCell(Grid, RadiusUpper, PsiUpper);
      Candidate.Source := 'starter-corner-upper-upper';
      Candidate.Confidence := 0.92;
      AppendUniqueCandidate(Candidate);
    end
    else
    begin
      Candidate := GetGridCell(Grid, RadiusLower, PsiUpper);
      Candidate.Source := 'starter-corner-lower-upper';
      Candidate.Confidence := 0.95;
      AppendUniqueCandidate(Candidate);

      Candidate := GetGridCell(Grid, RadiusLower, PsiLower);
      Candidate.Source := 'starter-corner-lower-lower';
      Candidate.Confidence := 0.94;
      AppendUniqueCandidate(Candidate);

      Candidate := GetGridCell(Grid, RadiusUpper, PsiUpper);
      Candidate.Source := 'starter-corner-upper-upper';
      Candidate.Confidence := 0.93;
      AppendUniqueCandidate(Candidate);

      Candidate := GetGridCell(Grid, RadiusUpper, PsiLower);
      Candidate.Source := 'starter-corner-upper-lower';
      Candidate.Confidence := 0.92;
      AppendUniqueCandidate(Candidate);
    end;
  end
  else
  begin
    if PsiMix <= 0.5 then
    begin
      Candidate := GetGridCell(Grid, RadiusUpper, PsiLower);
      Candidate.Source := 'starter-corner-upper-lower';
      Candidate.Confidence := 0.95;
      AppendUniqueCandidate(Candidate);

      Candidate := GetGridCell(Grid, RadiusUpper, PsiUpper);
      Candidate.Source := 'starter-corner-upper-upper';
      Candidate.Confidence := 0.94;
      AppendUniqueCandidate(Candidate);

      Candidate := GetGridCell(Grid, RadiusLower, PsiLower);
      Candidate.Source := 'starter-corner-lower-lower';
      Candidate.Confidence := 0.93;
      AppendUniqueCandidate(Candidate);

      Candidate := GetGridCell(Grid, RadiusLower, PsiUpper);
      Candidate.Source := 'starter-corner-lower-upper';
      Candidate.Confidence := 0.92;
      AppendUniqueCandidate(Candidate);
    end
    else
    begin
      Candidate := GetGridCell(Grid, RadiusUpper, PsiUpper);
      Candidate.Source := 'starter-corner-upper-upper';
      Candidate.Confidence := 0.95;
      AppendUniqueCandidate(Candidate);

      Candidate := GetGridCell(Grid, RadiusUpper, PsiLower);
      Candidate.Source := 'starter-corner-upper-lower';
      Candidate.Confidence := 0.94;
      AppendUniqueCandidate(Candidate);

      Candidate := GetGridCell(Grid, RadiusLower, PsiUpper);
      Candidate.Source := 'starter-corner-lower-upper';
      Candidate.Confidence := 0.93;
      AppendUniqueCandidate(Candidate);

      Candidate := GetGridCell(Grid, RadiusLower, PsiLower);
      Candidate.Source := 'starter-corner-lower-lower';
      Candidate.Confidence := 0.92;
      AppendUniqueCandidate(Candidate);
    end;
  end;

  PsiJitter := Max(Pi / 72, Abs(BaseSeed.DesStrAng) * 0.05);
  Candidate := PerturbStarterSeed(BaseSeed, 0.94, 0, 'starter-bilinear-swtd-low', 0.9);
  AppendUniqueCandidate(Candidate);

  Candidate := PerturbStarterSeed(BaseSeed, 1.06, 0, 'starter-bilinear-swtd-high', 0.89);
  AppendUniqueCandidate(Candidate);

  Candidate := PerturbStarterSeed(BaseSeed, 1.0, -PsiJitter, 'starter-bilinear-des-low', 0.88);
  AppendUniqueCandidate(Candidate);

  Candidate := PerturbStarterSeed(BaseSeed, 1.0, PsiJitter, 'starter-bilinear-des-high', 0.87);
  AppendUniqueCandidate(Candidate);

  Candidate := PerturbStarterSeed(BaseSeed, 0.97, -PsiJitter * 0.5, 'starter-bilinear-diagonal-low', 0.86);
  AppendUniqueCandidate(Candidate);

  Candidate := PerturbStarterSeed(BaseSeed, 1.03, PsiJitter * 0.5, 'starter-bilinear-diagonal-high', 0.85);
  AppendUniqueCandidate(Candidate);

  PriorSeed := BuildPriorProfileSeed(RawPsiDegrees, RadiusValue, BaseSeed);
  PriorSeed.Source := 'starter-prior-profile';
  PriorSeed.Confidence := 0.5;
  AppendUniqueCandidate(PriorSeed);
end;

end.
