unit SimpleArcSolver;

interface

uses
  SysUtils,
  Math,
  PoseSolver;

type
  TSolverReason = ShortString;

  TVector2D = record
    X: Double;
    Y: Double;
  end;

  TVehicleVector = record
    X: Double;
    Y: Double;
    Angle: Double;
    Length: Double;
  end;

  TArcGeometry = record
    Radius: Double;
    HeadingChange: Double;
    MaxHeadingChange: Double;
  end;

  TArcBisectorGeometry = record
    Valid: Boolean;
    Radius: Double;
    CurveLength: Double;
    TurnAngle: Double;
    Center: TVector2D;
    StartAngle: Double;
    BisectorAngle: Double;
    BisectorOrigin: TVector2D;
    BisectorDir: TVector2D;
  end;

  TAlignmentScore = record
    Score: Double;
    LineError: Double;
    NormalizedLineError: Double;
    PerpendicularError: Double;
    DistanceScale: Double;
  end;

  TAlignmentEvaluation = record
    Sl: Double;
    Error: Double;
    Geometry: TArcBisectorGeometry;
    Intersection: TVector2D;
    EndPose: TVehiclePose;
    Cor: TVector2D;
    CorDistance: Double;
    RearDistance: Double;
    BodyAlignment: Double;
    BodyAngleError: Double;
    HeadingChange: Double;
    CurveLength: Double;
    Score: Double;
  end;

  TBracket = record
    Valid: Boolean;
    Left: Double;
    Right: Double;
    FLeft: Double;
    FRight: Double;
  end;

  THeadingChangeSearchResult = record
    Success: Boolean;
    HeadingChange: Double;
    CurveLength: Double;
    Error: Double;
    Reason: TSolverReason;
    Geometry: TArcBisectorGeometry;
    Evaluation: TAlignmentEvaluation;
    Bracket: TBracket;
    Iterations: Integer;
    Value: Double;
  end;

  TSolverOptions = record
    InitialSl: Double;
    MaxSpan: Double;
    Passes: Integer;
    SampleCount: Integer;
    Tolerance: Double;
    BodyTolerance: Double;
  end;

  TSimpleArcSolution = record
    Success: Boolean;
    Sl: Double;
    HeadingChange: Double;
    CurveLength: Double;
    Error: Double;
    Reason: TSolverReason;
    InitialSl: Double;
    MaxSpan: Double;
    Geometry: TArcBisectorGeometry;
    Intersection: TVector2D;
    Cor: TVector2D;
    Evaluation: TAlignmentEvaluation;
    Inner: THeadingChangeSearchResult;
    Iterations: Integer;
    Value: Double;
    RearDistance: Double;
    BodyAlignment: Double;
    BodyAngleError: Double;
  end;

function DefaultSolverOptions: TSolverOptions;

function GetHeadingChange(const Geometry: TArcGeometry): Double;
function GetCurveLengthFromGeometry(const Geometry: TArcGeometry): Double;
function GetVehicleCorPoint(const Geometry: TArcGeometry): TVector2D;
function GetCurrentTurnBisectorGeometry(
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry
): TArcBisectorGeometry;

function EvaluateVehicleBisectorAlignmentError(
  const CandidateSl: Double;
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry
): TAlignmentEvaluation;

function ScoreVehicleBisectorAlignment(
  const Evaluation: TAlignmentEvaluation;
  const Geometry: TArcGeometry
): TAlignmentScore;

function SolveVehicleHeadingChangeForBisectorAlignment(
  const CandidateSl: Double;
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry
): THeadingChangeSearchResult;

function EvaluateVehicleCombinedAlignment(
  const CandidateSl: Double;
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry
): TAlignmentEvaluation; overload;

function EvaluateVehicleCombinedAlignment(
  const CandidateSl: Double;
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry;
  var Inner: THeadingChangeSearchResult
): TAlignmentEvaluation; overload;

function EvaluateVehicleCombinedAlignment(
  const CandidateSl: Double;
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry;
  const Options: TSolverOptions
): TAlignmentEvaluation; overload;

function SolveVehicleSlForBisectorAlignment(
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry;
  const Options: TSolverOptions
): TSimpleArcSolution; overload;

function SolveVehicleSlForBisectorAlignment(
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry
): TSimpleArcSolution; overload;

function SolveSimpleArc(
  const Radius, HeadingChange, InitialSl: Double;
  const VehicleVector: TVehicleVector
): TSimpleArcSolution;

implementation

type
  TSearchCandidate = record
    Valid: Boolean;
    X: Double;
    Y: Double;
  end;

  TRootSearchResult = record
    Success: Boolean;
    Reason: TSolverReason;
    Root: Double;
    Value: Double;
    Iterations: Integer;
    Bracket: TBracket;
  end;

function IsFiniteDouble(const Value: Double): Boolean;
begin
  Result := (not IsNan(Value)) and (Abs(Value) < 1.0E300);
end;

function MakeVector(const X, Y: Double): TVector2D;
begin
  Result.X := X;
  Result.Y := Y;
end;

function MakeGeometry(const Radius, HeadingChange, MaxHeadingChange: Double): TArcGeometry;
begin
  Result.Radius := Radius;
  Result.HeadingChange := HeadingChange;
  Result.MaxHeadingChange := MaxHeadingChange;
end;

function ClampDouble(const Value, AMin, AMax: Double): Double;
begin
  Result := Value;
  if Result < AMin then
    Result := AMin
  else if Result > AMax then
    Result := AMax;
end;

function NormalizePointDirection(const Vector: TVector2D): TVector2D;
var
  LengthValue: Double;
begin
  LengthValue := Hypot(Vector.X, Vector.Y);
  if LengthValue <= 0 then
  begin
    Result.X := 0;
    Result.Y := 0;
  end;
  if LengthValue > 0 then
  begin
    Result.X := Vector.X / LengthValue;
    Result.Y := Vector.Y / LengthValue;
  end;
end;

function Dot2(const A, B: TVector2D): Double;
begin
  Result := A.X * B.X + A.Y * B.Y;
end;

function Cross2(const A, B: TVector2D): Double;
begin
  Result := A.X * B.Y - A.Y * B.X;
end;

function IntersectLines(
  const P1, D1, P2, D2: TVector2D;
  out Point: TVector2D
): Boolean;
var
  Determinant: Double;
  Dx, Dy, T: Double;
begin
  Determinant := D1.X * D2.Y - D1.Y * D2.X;
  if Abs(Determinant) < 1e-9 then
  begin
    Result := False;
    Point.X := 0;
    Point.Y := 0;
  end;
  if Abs(Determinant) >= 1e-9 then
  begin
    Dx := P2.X - P1.X;
    Dy := P2.Y - P1.Y;
    T := (Dx * D2.Y - Dy * D2.X) / Determinant;
    Point.X := P1.X + D1.X * T;
    Point.Y := P1.Y + D1.Y * T;
    Result := True;
  end;
end;

function GetVehiclePerpendicularIntersection(
  const Rear: TVector2D;
  const BodyAngle: Double;
  const Front: TVector2D;
  const SteerAngle: Double;
  out Point: TVector2D
): Boolean;
var
  BlueDirection, YellowDirection: TVector2D;
begin
  BlueDirection.X := -Sin(BodyAngle);
  BlueDirection.Y := Cos(BodyAngle);
  YellowDirection.X := -Sin(SteerAngle);
  YellowDirection.Y := Cos(SteerAngle);
  Result := IntersectLines(Rear, BlueDirection, Front, YellowDirection, Point);
end;

function DefaultSolverOptions: TSolverOptions;
begin
  Result.InitialSl := 0.01;
  Result.MaxSpan := 128;
  Result.Passes := 5;
  Result.SampleCount := 21;
  Result.Tolerance := 1e-7;
  Result.BodyTolerance := 1e-6;
end;

function GetHeadingChange(const Geometry: TArcGeometry): Double;
begin
  Result := Max(0, Geometry.HeadingChange);
end;

function GetCurveLengthFromGeometry(const Geometry: TArcGeometry): Double;
begin
  Result := Geometry.Radius * GetHeadingChange(Geometry);
end;

function GetVehicleCorPoint(const Geometry: TArcGeometry): TVector2D;
begin
  Result.X := 0;
  Result.Y := Geometry.Radius;
end;

function GetCurrentTurnBisectorGeometry(
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry
): TArcBisectorGeometry;
var
  RadiusValue, CurveLength, TurnAngle, StartAngle, BisectorAngle: Double;
begin
  RadiusValue := Geometry.Radius;
  CurveLength := Max(0, GetCurveLengthFromGeometry(Geometry));

  Result.Valid := False;
  Result.Radius := RadiusValue;
  Result.CurveLength := CurveLength;
  Result.TurnAngle := 0;
  Result.Center := MakeVector(0, 0);
  Result.StartAngle := 0;
  Result.BisectorAngle := 0;
  Result.BisectorOrigin := MakeVector(0, 0);
  Result.BisectorDir := MakeVector(0, 0);

  if (Abs(RadiusValue) > 1e-12) and (CurveLength > 0) then
  begin
    TurnAngle := CurveLength / RadiusValue;
    if RadiusValue >= 0 then
      StartAngle := -Pi / 2
    else
      StartAngle := Pi / 2;
    BisectorAngle := StartAngle + TurnAngle / 2;

    Result.Valid := True;
    Result.Radius := RadiusValue;
    Result.CurveLength := CurveLength;
    Result.TurnAngle := TurnAngle;
    Result.Center := GetVehicleCorPoint(Geometry);
    Result.StartAngle := StartAngle;
    Result.BisectorAngle := BisectorAngle;
    Result.BisectorOrigin := Result.Center;
    Result.BisectorDir := MakeVector(Cos(BisectorAngle), Sin(BisectorAngle));
  end;
end;

function EvaluateVehicleBisectorAlignmentError(
  const CandidateSl: Double;
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry
): TAlignmentEvaluation;
var
  BisectorGeometry: TArcBisectorGeometry;
  CurveLength, RadiusValue: Double;
  EndPose: TVehiclePose;
  Rear, Front, CorPoint, BodyDirection: TVector2D;
begin
  BisectorGeometry := GetCurrentTurnBisectorGeometry(VehicleVector, Geometry);
  Result := Default(TAlignmentEvaluation);
  Result.Sl := CandidateSl;
  Result.Geometry := BisectorGeometry;
  Result.Error := NaN;
  Result.CorDistance := NaN;
  Result.RearDistance := NaN;
  Result.BodyAlignment := NaN;
  Result.BodyAngleError := NaN;
  Result.Score := NaN;

  if BisectorGeometry.Valid then
  begin
    CurveLength := Max(0, GetCurveLengthFromGeometry(Geometry));
    RadiusValue := Geometry.Radius;
    EndPose := SampleVehiclePoseForSlew(
      VehicleVector.X,
      VehicleVector.Y,
      VehicleVector.Angle,
      CurveLength,
      CandidateSl,
      CurveLength,
      RadiusValue
    );

    Rear := MakeVector(EndPose.X, EndPose.Y);
    Front := MakeVector(
      Rear.X + Cos(EndPose.Angle),
      Rear.Y + Sin(EndPose.Angle)
    );

    if GetVehiclePerpendicularIntersection(
      Rear,
      EndPose.Angle,
      Front,
      EndPose.Angle + EndPose.Theta,
      CorPoint
    ) then
    begin
      Result.Intersection := CorPoint;
      Result.Cor := CorPoint;
      Result.CorDistance := Cross2(
        MakeVector(
          CorPoint.X - BisectorGeometry.BisectorOrigin.X,
          CorPoint.Y - BisectorGeometry.BisectorOrigin.Y
        ),
        BisectorGeometry.BisectorDir
      );
      Result.RearDistance := Result.CorDistance;
    end
    else
    begin
      Result.Intersection := MakeVector(0, 0);
      Result.Cor := MakeVector(0, 0);
      Result.CorDistance := NaN;
      Result.RearDistance := NaN;
    end;

    BodyDirection := NormalizePointDirection(MakeVector(Cos(EndPose.Angle), Sin(EndPose.Angle)));
    if (BodyDirection.X = 0) and (BodyDirection.Y = 0) then
      Result.BodyAlignment := NaN
    else
      Result.BodyAlignment := Dot2(BodyDirection, BisectorGeometry.BisectorDir);

    Result.EndPose := EndPose;
    Result.HeadingChange := Geometry.HeadingChange;
    Result.CurveLength := CurveLength;
    Result.Error := Result.CorDistance;
  end;
end;

function ScoreVehicleBisectorAlignment(
  const Evaluation: TAlignmentEvaluation;
  const Geometry: TArcGeometry
): TAlignmentScore;
var
  LineError, BodyAlignmentValue, PerpendicularError, DistanceScale, NormalizedLineError: Double;
begin
  Result.Score := NaN;
  Result.LineError := NaN;
  Result.NormalizedLineError := NaN;
  Result.PerpendicularError := NaN;
  Result.DistanceScale := NaN;

  if Evaluation.Geometry.Valid then
  begin
    if IsFiniteDouble(Evaluation.CorDistance) then
      LineError := Evaluation.CorDistance
    else
      LineError := Evaluation.RearDistance;

    BodyAlignmentValue := Evaluation.BodyAlignment;
    if (not IsFiniteDouble(LineError)) or (not IsFiniteDouble(BodyAlignmentValue)) then
      Result.LineError := LineError
    else
    begin
      PerpendicularError := ArcSin(ClampDouble(BodyAlignmentValue, -1, 1));
      DistanceScale := Max(1, Abs(Evaluation.Geometry.Radius));
      DistanceScale := Max(DistanceScale, Abs(Evaluation.Geometry.CurveLength));
      DistanceScale := Max(DistanceScale, Abs(Geometry.Radius));
      DistanceScale := Max(DistanceScale, Abs(GetCurveLengthFromGeometry(Geometry)));
      NormalizedLineError := LineError / DistanceScale;

      Result.Score := Sqr(NormalizedLineError) + Sqr(PerpendicularError);
      Result.LineError := LineError;
      Result.NormalizedLineError := NormalizedLineError;
      Result.PerpendicularError := PerpendicularError;
      Result.DistanceScale := DistanceScale;
    end;
  end;
end;

function SolveVehicleHeadingChangeForBisectorAlignment(
  const CandidateSl: Double;
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry
): THeadingChangeSearchResult;
var
  StartHeadingChange, MaxSpan, InitialSpan, Tolerance: Double;
  Bracket: TBracket;
  RootResult: TRootSearchResult;
  BestHeadingChange: Double;
  Evaluation: TAlignmentEvaluation;
  Score: TAlignmentScore;
  BestCandidate: TSearchCandidate;
  AdjustedGeometry: TArcGeometry;
  BisectorGeometry: TArcBisectorGeometry;

  function CorDistanceAt(const HeadingChange: Double): Double;
  var
    AdjustedGeometry: TArcGeometry;
  begin
    AdjustedGeometry := Geometry;
    AdjustedGeometry.HeadingChange := HeadingChange;
    Result := EvaluateVehicleBisectorAlignmentError(CandidateSl, VehicleVector, AdjustedGeometry).CorDistance;
  end;

  function ScoreAt(const HeadingChange: Double): Double;
  var
    AdjustedGeometry: TArcGeometry;
    Evaluation: TAlignmentEvaluation;
    Score: TAlignmentScore;
  begin
    AdjustedGeometry := Geometry;
    AdjustedGeometry.HeadingChange := HeadingChange;
    Evaluation := EvaluateVehicleBisectorAlignmentError(CandidateSl, VehicleVector, AdjustedGeometry);
    Score := ScoreVehicleBisectorAlignment(Evaluation, AdjustedGeometry);
    Result := Score.Score;
  end;

  function FindPositiveSignChangeBracket: TBracket;
  var
    Span, LeftValue, RightValue, Left, Right, Step, SampleX, SampleY: Double;
    Attempt, Index: Integer;
    PreviousX, PreviousY: Double;
    FoundBracket: Boolean;
  begin
    Result.Valid := False;
    Span := Max(1e-3, Abs(InitialSpan));
    FoundBracket := False;

    for Attempt := 0 to 11 do
    begin
      if (Span <= MaxSpan) and (not FoundBracket) then
      begin
        Left := Max(0, StartHeadingChange - Span);
        Right := Max(Left + 1e-6, StartHeadingChange + Span);
        Step := (Right - Left) / 10;
        PreviousX := Left;
        PreviousY := CorDistanceAt(PreviousX);

        for Index := 1 to 10 do
        begin
          if not FoundBracket then
          begin
            SampleX := Left + Step * Index;
            SampleY := CorDistanceAt(SampleX);
            if not IsFiniteDouble(PreviousY) or not IsFiniteDouble(SampleY) then
            begin
              PreviousX := SampleX;
              PreviousY := SampleY;
            end
            else if PreviousY = 0 then
            begin
              Result.Valid := True;
              Result.Left := PreviousX;
              Result.Right := PreviousX;
              Result.FLeft := PreviousY;
              Result.FRight := PreviousY;
              FoundBracket := True;
            end
            else if SampleY = 0 then
            begin
              Result.Valid := True;
              Result.Left := SampleX;
              Result.Right := SampleX;
              Result.FLeft := SampleY;
              Result.FRight := SampleY;
              FoundBracket := True;
            end
            else if PreviousY * SampleY < 0 then
            begin
              Result.Valid := True;
              Result.Left := PreviousX;
              Result.Right := SampleX;
              Result.FLeft := PreviousY;
              Result.FRight := SampleY;
              FoundBracket := True;
            end
            else
            begin
              PreviousX := SampleX;
              PreviousY := SampleY;
            end;
          end;
        end;

        if not FoundBracket then
          Span := Span * 2;
      end;
    end;
  end;

  function SolveBracketedRoot(const A, B, FA, FB: Double): TRootSearchResult;
  var
    Left, Right, FLeft, FRight, Candidate, FCandidate: Double;
    Iteration: Integer;
    Finished: Boolean;
  begin
    Result.Success := False;
    Result.Reason := 'invalid-bracket';
    Result.Root := NaN;
    Result.Value := NaN;
    Result.Iterations := 0;
    Result.Bracket.Valid := False;
    Result.Bracket.Left := A;
    Result.Bracket.Right := B;
    Result.Bracket.FLeft := FA;
    Result.Bracket.FRight := FB;

    Left := A;
    Right := B;
    FLeft := FA;
    FRight := FB;
    Finished := False;

    if (not IsFiniteDouble(FLeft)) or (not IsFiniteDouble(FRight)) or (FLeft * FRight > 0) then
      Finished := True
    else if Abs(FLeft) <= Tolerance then
    begin
      Result.Success := True;
      Result.Reason := 'endpoint-root';
      Result.Root := Left;
      Result.Value := FLeft;
      Result.Iterations := 0;
      Result.Bracket.Valid := True;
      Result.Bracket.Left := Left;
      Result.Bracket.Right := Right;
      Result.Bracket.FLeft := FLeft;
      Result.Bracket.FRight := FRight;
      Finished := True;
    end;
    if (not Finished) and (Abs(FRight) <= Tolerance) then
    begin
      Result.Success := True;
      Result.Reason := 'endpoint-root';
      Result.Root := Right;
      Result.Value := FRight;
      Result.Iterations := 0;
      Result.Bracket.Valid := True;
      Result.Bracket.Left := Left;
      Result.Bracket.Right := Right;
      Result.Bracket.FLeft := FLeft;
      Result.Bracket.FRight := FRight;
      Finished := True;
    end;

    for Iteration := 1 to 64 do
    begin
      if not Finished then
      begin
        if (IsFiniteDouble(FLeft)) and (IsFiniteDouble(FRight)) and (FRight <> FLeft) then
          Candidate := Right - (FRight * (Right - Left)) / (FRight - FLeft)
        else
          Candidate := (Left + Right) / 2;

        if (not IsFiniteDouble(Candidate)) or (Candidate <= Min(Left, Right)) or (Candidate >= Max(Left, Right)) then
          Candidate := (Left + Right) / 2;

        FCandidate := CorDistanceAt(Candidate);
        if not IsFiniteDouble(FCandidate) then
        begin
          Candidate := (Left + Right) / 2;
          FCandidate := CorDistanceAt(Candidate);
        end;

        if not IsFiniteDouble(FCandidate) then
          Finished := True
        else if (Abs(FCandidate) <= Tolerance) or (Abs(Right - Left) <= Tolerance) then
        begin
          Result.Success := True;
          Result.Reason := 'converged';
          Result.Root := Candidate;
          Result.Value := FCandidate;
          Result.Iterations := Iteration;
          Result.Bracket.Valid := True;
          Result.Bracket.Left := Left;
          Result.Bracket.Right := Right;
          Result.Bracket.FLeft := FLeft;
          Result.Bracket.FRight := FRight;
          Finished := True;
        end
        else if FLeft * FCandidate <= 0 then
        begin
          Right := Candidate;
          FRight := FCandidate;
        end
        else
        begin
          Left := Candidate;
          FLeft := FCandidate;
        end;
      end;
    end;

    Result.Root := Candidate;
    Result.Value := FCandidate;
    Result.Iterations := 64;
    Result.Reason := 'max-iterations';
  end;

  function SearchPositiveMinimum: TSearchCandidate;
  var
    Left, Right, Width, Step, CandidateX, CandidateY: Double;
    Pass, Index, Count, BestIndex: Integer;
    LocalBestX, LocalBestY: Double;
    StopSearch: Boolean;
  begin
    Result.Valid := False;
    Result.X := ClampDouble(StartHeadingChange, 0, MaxSpan);
    Result.Y := 1.0E300;

    CandidateY := ScoreAt(Result.X);
    if IsFiniteDouble(CandidateY) and (CandidateY < Result.Y) then
      Result.Y := CandidateY;

    Left := 0;
    Right := Max(0, MaxSpan);
    StopSearch := False;

    for Pass := 0 to 4 do
    begin
      if not StopSearch then
      begin
        Count := Max(5, 21 - Pass * 2);
        Width := Max(1e-6, Right - Left);
        LocalBestX := Result.X;
        LocalBestY := Result.Y;
        BestIndex := 0;

        CandidateY := ScoreAt(Left);
        if IsFiniteDouble(CandidateY) and (CandidateY < LocalBestY) then
        begin
          LocalBestX := Left;
          LocalBestY := CandidateY;
          BestIndex := 0;
        end;

        for Index := 1 to Count - 1 do
        begin
          CandidateX := Left + Width * (Index / (Count - 1));
          CandidateY := ScoreAt(CandidateX);
          if IsFiniteDouble(CandidateY) and (CandidateY < LocalBestY) then
          begin
            LocalBestX := CandidateX;
            LocalBestY := CandidateY;
            BestIndex := Index;
          end;
        end;

        Result.X := LocalBestX;
        Result.Y := LocalBestY;

        Step := Width / (Count - 1);
        Left := ClampDouble(LocalBestX - Step, 0, MaxSpan);
        Right := ClampDouble(LocalBestX + Step, 0, MaxSpan);

        if Abs(Right - Left) <= 1e-6 then
          StopSearch := True
        else if BestIndex = 0 then
          Right := Min(MaxSpan, Left + Max(Step * 2, 1e-3))
        else if BestIndex = Count - 1 then
          Left := Max(0, Right - Max(Step * 2, 1e-3));
      end;
    end;

    Result.Y := ScoreAt(Result.X);
  end;

  begin
    Result := Default(THeadingChangeSearchResult);
    BisectorGeometry := GetCurrentTurnBisectorGeometry(VehicleVector, Geometry);
    if not BisectorGeometry.Valid then
    begin
      Result.Success := False;
      Result.HeadingChange := NaN;
      Result.CurveLength := NaN;
      Result.Error := NaN;
      Result.Reason := 'invalid-geometry';
      Result.Geometry := BisectorGeometry;
    end;
    if BisectorGeometry.Valid then
    begin
      StartHeadingChange := Max(0, GetHeadingChange(Geometry));
      if IsFiniteDouble(Geometry.MaxHeadingChange) then
        MaxSpan := Abs(Geometry.MaxHeadingChange)
      else
        MaxSpan := 100;
      InitialSpan := Max(0.5, StartHeadingChange * 0.5 + 0.5);
      Tolerance := 1e-7;

      Bracket := FindPositiveSignChangeBracket;
      if Bracket.Valid then
      begin
        RootResult := SolveBracketedRoot(Bracket.Left, Bracket.Right, Bracket.FLeft, Bracket.FRight);
        if RootResult.Success then
        begin
          BestHeadingChange := Max(0, RootResult.Root);
          Evaluation := EvaluateVehicleBisectorAlignmentError(CandidateSl, VehicleVector, MakeGeometry(Geometry.Radius, BestHeadingChange, Geometry.MaxHeadingChange));
          Result.Success := IsFiniteDouble(Evaluation.CorDistance) and (Abs(Evaluation.CorDistance) <= Tolerance);
          Result.HeadingChange := BestHeadingChange;
          Result.CurveLength := GetCurveLengthFromGeometry(MakeGeometry(Geometry.Radius, BestHeadingChange, Geometry.MaxHeadingChange));
          Result.Error := Evaluation.CorDistance;
          Result.Reason := RootResult.Reason;
          Result.Geometry := Evaluation.Geometry;
          Result.Evaluation := Evaluation;
          Result.Bracket := RootResult.Bracket;
          Result.Iterations := RootResult.Iterations;
          Result.Value := RootResult.Value;
        end;
      end;

      if not RootResult.Success then
      begin
        BestCandidate := SearchPositiveMinimum;
        BestHeadingChange := Max(0, BestCandidate.X);
        AdjustedGeometry := MakeGeometry(Geometry.Radius, BestHeadingChange, Geometry.MaxHeadingChange);
        Evaluation := EvaluateVehicleBisectorAlignmentError(CandidateSl, VehicleVector, AdjustedGeometry);
        Score := ScoreVehicleBisectorAlignment(Evaluation, AdjustedGeometry);
        Result.Success := IsFiniteDouble(Evaluation.CorDistance) and (Abs(Evaluation.CorDistance) <= Tolerance);
        Result.HeadingChange := BestHeadingChange;
        Result.CurveLength := GetCurveLengthFromGeometry(AdjustedGeometry);
        Result.Error := Evaluation.CorDistance;
        Result.Reason := 'minimum-search';
        Result.Geometry := Evaluation.Geometry;
        Result.Evaluation := Evaluation;
        Result.Bracket.Valid := False;
        Result.Iterations := 5 * 21;
        Result.Value := Score.Score;
      end;
    end;
  end;

function EvaluateVehicleCombinedAlignment(
  const CandidateSl: Double;
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry
): TAlignmentEvaluation;
var
  Inner: THeadingChangeSearchResult;
begin
  Inner := Default(THeadingChangeSearchResult);
  Result := EvaluateVehicleCombinedAlignment(CandidateSl, VehicleVector, Geometry, Inner);
end;

function EvaluateVehicleCombinedAlignment(
  const CandidateSl: Double;
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry;
  var Inner: THeadingChangeSearchResult
): TAlignmentEvaluation;
var
  Score: TAlignmentScore;
begin
  Inner := SolveVehicleHeadingChangeForBisectorAlignment(CandidateSl, VehicleVector, Geometry);
  Result := Inner.Evaluation;
  Result.HeadingChange := Inner.HeadingChange;
  Result.CurveLength := Inner.CurveLength;

  if (not Result.Geometry.Valid) or (not IsFiniteDouble(Result.EndPose.X)) or (not IsFiniteDouble(Result.EndPose.Y)) then
  begin
    Result.BodyAngleError := NaN;
    Result.Score := NaN;
  end;
  if Result.Geometry.Valid and IsFiniteDouble(Result.EndPose.X) and IsFiniteDouble(Result.EndPose.Y) then
  begin
    Score := ScoreVehicleBisectorAlignment(Result, Geometry);
    Result.BodyAngleError := Score.PerpendicularError;
    Result.Score := Score.Score;
  end;
end;

function EvaluateVehicleCombinedAlignment(
  const CandidateSl: Double;
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry;
  const Options: TSolverOptions
): TAlignmentEvaluation;
begin
  Result := EvaluateVehicleCombinedAlignment(CandidateSl, VehicleVector, Geometry);
end;

function SolveVehicleSlForBisectorAlignment(
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry;
  const Options: TSolverOptions
): TSimpleArcSolution;
var
  StartSl, MaxSpan, Tolerance, BodyTolerance: Double;
  Passes, SampleCount: Integer;
  BestCandidate: TSearchCandidate;
  Evaluation: TAlignmentEvaluation;
  RearAligned, BodyAligned: Boolean;

  function CombinedScoreAt(const SlValue: Double): Double;
  var
    Evaluation: TAlignmentEvaluation;
  begin
    Evaluation := EvaluateVehicleCombinedAlignment(SlValue, VehicleVector, Geometry);
    Result := Evaluation.Score;
  end;

  function SearchPositiveMinimum: TSearchCandidate;
  var
    Left, Right, Width, Step, CandidateX, CandidateY: Double;
    Pass, Index, Count, BestIndex: Integer;
    LocalBestX, LocalBestY: Double;
    StopSearch: Boolean;
  begin
    Result.Valid := False;
    Result.X := ClampDouble(StartSl, 0, MaxSpan);
    Result.Y := 1.0E300;

    CandidateY := CombinedScoreAt(Result.X);
    if IsFiniteDouble(CandidateY) and (CandidateY < Result.Y) then
      Result.Y := CandidateY;

    Left := 0;
    Right := Max(0, MaxSpan);
    StopSearch := False;

    for Pass := 0 to Passes - 1 do
    begin
      if not StopSearch then
      begin
        Count := Max(5, SampleCount - Pass * 2);
        Width := Max(1e-6, Right - Left);
        LocalBestX := Result.X;
        LocalBestY := Result.Y;
        BestIndex := 0;

        CandidateY := CombinedScoreAt(Left);
        if IsFiniteDouble(CandidateY) and (CandidateY < LocalBestY) then
        begin
          LocalBestX := Left;
          LocalBestY := CandidateY;
          BestIndex := 0;
        end;

        for Index := 1 to Count - 1 do
        begin
          CandidateX := Left + Width * (Index / (Count - 1));
          CandidateY := CombinedScoreAt(CandidateX);
          if IsFiniteDouble(CandidateY) and (CandidateY < LocalBestY) then
          begin
            LocalBestX := CandidateX;
            LocalBestY := CandidateY;
            BestIndex := Index;
          end;
        end;

        Result.X := LocalBestX;
        Result.Y := LocalBestY;

        Step := Width / (Count - 1);
        Left := ClampDouble(LocalBestX - Step, 0, MaxSpan);
        Right := ClampDouble(LocalBestX + Step, 0, MaxSpan);

        if Abs(Right - Left) <= 1e-6 then
          StopSearch := True
        else if BestIndex = 0 then
          Right := Min(MaxSpan, Left + Max(Step * 2, 1e-3))
        else if BestIndex = Count - 1 then
          Left := Max(0, Right - Max(Step * 2, 1e-3));
      end;
    end;

    Result.Y := CombinedScoreAt(Result.X);
  end;

begin
  Result := Default(TSimpleArcSolution);

  StartSl := 0.01;
  MaxSpan := 128;
  Passes := 5;
  SampleCount := 21;
  Tolerance := 1e-7;
  BodyTolerance := 1e-6;

  if IsFiniteDouble(Options.InitialSl) and (Options.InitialSl > 0) then
    StartSl := Options.InitialSl;
  if IsFiniteDouble(Options.MaxSpan) and (Options.MaxSpan > 0) then
    MaxSpan := Options.MaxSpan;
  if Options.Passes > 0 then
    Passes := Options.Passes;
  if Options.SampleCount > 0 then
    SampleCount := Options.SampleCount;
  if IsFiniteDouble(Options.Tolerance) and (Options.Tolerance > 0) then
    Tolerance := Options.Tolerance;
  if IsFiniteDouble(Options.BodyTolerance) and (Options.BodyTolerance > 0) then
    BodyTolerance := Options.BodyTolerance;

  BestCandidate := SearchPositiveMinimum;
  Evaluation := EvaluateVehicleCombinedAlignment(BestCandidate.X, VehicleVector, Geometry, Result.Inner);
  RearAligned := IsFiniteDouble(Evaluation.RearDistance) and (Abs(Evaluation.RearDistance) <= Tolerance);
  BodyAligned := IsFiniteDouble(Evaluation.BodyAlignment) and (Abs(Evaluation.BodyAlignment) <= BodyTolerance);

  Result.Success := RearAligned and BodyAligned;
  Result.Sl := Max(0, BestCandidate.X);
  Result.HeadingChange := Max(0, Evaluation.HeadingChange);
  Result.CurveLength := Max(0, Evaluation.CurveLength);
  Result.Error := Evaluation.Score;
  if RearAligned and BodyAligned then
    Result.Reason := 'converged'
  else
    Result.Reason := 'alignment-mismatch';
  Result.InitialSl := StartSl;
  Result.MaxSpan := MaxSpan;
  Result.Geometry := Evaluation.Geometry;
  Result.Intersection := Evaluation.Intersection;
  Result.Cor := Evaluation.Cor;
  Result.Evaluation := Evaluation;
  Result.Iterations := Passes * SampleCount;
  Result.Value := Evaluation.Score;
  Result.RearDistance := Evaluation.RearDistance;
  Result.BodyAlignment := Evaluation.BodyAlignment;
  Result.BodyAngleError := Evaluation.BodyAngleError;
end;

function SolveVehicleSlForBisectorAlignment(
  const VehicleVector: TVehicleVector;
  const Geometry: TArcGeometry
): TSimpleArcSolution;
begin
  Result := SolveVehicleSlForBisectorAlignment(VehicleVector, Geometry, DefaultSolverOptions);
end;

function SolveSimpleArc(
  const Radius, HeadingChange, InitialSl: Double;
  const VehicleVector: TVehicleVector
): TSimpleArcSolution;
var
  Geometry: TArcGeometry;
  Options: TSolverOptions;
begin
  Geometry := MakeGeometry(Radius, HeadingChange, 100);
  Options := DefaultSolverOptions;
  Options.InitialSl := InitialSl;
  Result := SolveVehicleSlForBisectorAlignment(VehicleVector, Geometry, Options);
end;

end.
