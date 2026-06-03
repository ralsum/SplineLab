program SplineLabServer;

{$mode delphi}

uses
  Classes,
  SysUtils,
  fphttpserver,
  httpdefs;

type
  TStaticServer = class
  private
    FBaseDir: string;
    function ResolveRequestPath(const URI: string): string;
    function GuessMimeType(const FileName: string): string;
    procedure SendTextResponse(var Response: TFPHTTPConnectionResponse; const Code: Integer; const CodeText, Body: string);
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

procedure TStaticServer.RequestHandler(Sender: TObject; var Request: TFPHTTPConnectionRequest; var Response: TFPHTTPConnectionResponse);
var
  FilePath, EffectivePath: string;
  Stream: TFileStream;
begin
  if (Request.Method <> 'GET') and (Request.Method <> 'HEAD') then
  begin
    Response.CustomHeaders.Values['Allow'] := 'GET, HEAD';
    SendTextResponse(Response, 405, 'Method Not Allowed', 'Only GET and HEAD are supported.' + LineEnding);
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
    ReadLn;
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
