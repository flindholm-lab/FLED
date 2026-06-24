program FlabEditor;

{$R-,S-,I-} { Disable runtime bounds checking to prevent false IDE crashes }

uses
  Dos;

const
  MAX_LINES = 12000; { Easily holds hundreds of KB in heap memory }
  MAX_DIR_FILES = 512;
  LINE_WIDTH = 80;
  VIEWPORT_HEIGHT = 23;

  { Custom color constants }
  Black = 0;
  Blue = 1;
  LightGray = 7;
  DarkGray = 8;
  LightGreen = 10;
  LightCyan = 11;
  LightRed = 12;
  Yellow = 14;
  White = 15;

  { UI Message and String Constants }
  msg_no_file   = 'No file loaded. Press F2 to Open.';
  msg_not_found = 'Text not found!';
  msg_pause     = 'Press ESC to Abort, Any Key to Continue...';
  msg_match     = 'Files match exactly.';
  
  { Prompts }
  prompt_open1  = 'Choose file to Open:';
  prompt_open2  = 'Choose 2nd file to Compare:';
  prompt_save   = 'Type filename to Save:';
  prompt_search = 'Type text to Search:';
  msg_avail     = 'Available Files (Use Arrows/PgUp/Dn):';
  
  hex_digits: string[16] = '0123456789ABCDEF';

type
  TScreenChar = record
    Ch: Char;
    Attr: Byte;
  end;
  TVideoMemory = array[1..25, 1..80] of TScreenChar;
  
  PString80 = ^TString80;
  TString80 = string[80];

var
  VRAM: TVideoMemory absolute $B800:0000;

  { Pointer array stored in Data Segment, pointing to exact strings in Heap }
  TextBuffer: array[1..MAX_LINES] of PString80;

  CursorAbsX: Integer; { 1..80 }
  CursorAbsY: Integer; { 1..MAX_LINES }
  ScrollTopY: Integer; { 1..MAX_LINES-1 }
  
  File1Name: string;
  File2Name: string;
  
  FileList: array[1..MAX_DIR_FILES] of string[14];
  FileCount: Integer;
  SelectedFile: Integer;

  CurrentAttr: Byte;
  CurrentX, CurrentY: Integer;
  ExtendedBuffer: Byte;

  InsertMode: Boolean;
  ResetStatus: Boolean;

{ Forward declarations }
procedure DrawUI; forward;
procedure DrawStatusBar; forward;
procedure RedrawTextViewport; forward;
procedure UpdateCursor; forward;
procedure LoadTextFile(FileName: string); forward;
procedure DoNew; forward;
procedure DoSave; forward;
procedure DoSearch; forward;
procedure DoCompare; forward;
procedure DoHex; forward;

{ Hardware Cursor Control }
procedure CursorOff; assembler;
asm
  mov ah, 01h
  mov ch, 20h
  mov cl, 00h
  int 10h
end;

procedure CursorOn;
begin
  if InsertMode then
  begin
    asm
      mov ah, 01h
      mov ch, 06h
      mov cl, 07h
      int 10h
    end;
  end
  else
  begin
    asm
      mov ah, 01h
      mov ch, 04h  { Thicker cursor for Overwrite mode }
      mov cl, 07h
      int 10h
    end;
  end;
end;

procedure GotoXY(X, Y: Integer);
begin
  CurrentX := X; CurrentY := Y;
  asm
    mov ah, 02h
    mov bh, 0
    mov dh, Byte(Y)
    dec dh
    mov dl, Byte(X)
    dec dl
    int 10h
  end;
end;

procedure TextColor(Col: Byte);
begin
  CurrentAttr := Byte((CurrentAttr and $F0) or (Col and $0F));
end;

procedure TextBackground(Col: Byte);
begin
  CurrentAttr := Byte((CurrentAttr and $0F) or ((Col and $07) shl 4));
end;

procedure Print(s: string);
var i: Integer;
begin
  for i := 1 to Length(s) do
  begin
    if CurrentX <= 80 then
    begin
      VRAM[CurrentY, CurrentX].Ch := s[i];
      VRAM[CurrentY, CurrentX].Attr := CurrentAttr;
      Inc(CurrentX);
    end;
  end;
  GotoXY(CurrentX, CurrentY);
end;

procedure WriteChars(Ch: Char; Count: Integer);
var i: Integer;
begin
  for i := 1 to Count do
  begin
    if CurrentX <= 80 then
    begin
      VRAM[CurrentY, CurrentX].Ch := Ch;
      VRAM[CurrentY, CurrentX].Attr := CurrentAttr;
      Inc(CurrentX);
    end;
  end;
  GotoXY(CurrentX, CurrentY);
end;

procedure PrintLn(s: string);
begin
  Print(s);
  if CurrentY < 25 then 
    GotoXY(1, CurrentY + 1) 
  else 
    GotoXY(1, 25);
end;

function KeyPressed: Boolean; assembler;
asm
  mov ah, 01h
  int 16h
  mov al, 0
  jz @done
  mov al, 1
@done:
end;

function ReadKey: Char;
var Scan, ASCII: Byte;
begin
  if ExtendedBuffer <> 0 then
  begin
    ReadKey := Char(ExtendedBuffer);
    ExtendedBuffer := 0; 
    Exit;
  end;
  
  asm
    mov ah, 00h
    int 16h
    mov Scan, ah
    mov ASCII, al
  end;
  
  if (ASCII = 0) or (ASCII = $E0) then
  begin
    ExtendedBuffer := Scan;
    ReadKey := #0;
  end 
  else 
    ReadKey := Char(ASCII);
end;

procedure ClrScr;
var r, c: Integer;
begin
  for r := 1 to 25 do
    for c := 1 to 80 do
    begin
      VRAM[r, c].Ch := ' ';
      VRAM[r, c].Attr := CurrentAttr;
    end;
end;

{ --- Heap Memory Buffer Management --- }
function GetLine(idx: Integer): string;
begin
  if (idx >= 1) and (idx <= MAX_LINES) and (TextBuffer[idx] <> nil) then
    GetLine := TextBuffer[idx]^
  else
    GetLine := '';
end;

procedure SetLine(idx: Integer; s: string);
begin
  if (idx >= 1) and (idx <= MAX_LINES) then
  begin
    if TextBuffer[idx] <> nil then
    begin
      if Length(TextBuffer[idx]^) = Length(s) then
      begin
        TextBuffer[idx]^ := s;
        Exit;
      end;
      FreeMem(TextBuffer[idx], Length(TextBuffer[idx]^) + 1);
      TextBuffer[idx] := nil;
    end;
    
    if MaxAvail < Length(s) + 1 then Exit;
    
    GetMem(TextBuffer[idx], Length(s) + 1);
    TextBuffer[idx]^ := s;
  end;
end;

procedure InitTextBuffer;
var i: Integer;
begin
  for i := 1 to MAX_LINES do
  begin
    if TextBuffer[i] <> nil then
    begin
      FreeMem(TextBuffer[i], Length(TextBuffer[i]^) + 1);
      TextBuffer[i] := nil;
    end;
  end;
end;

function TrimTrailingSpaces(s: string): string;
var i: Integer;
begin
  i := Length(s);
  while (i > 0) and (s[i] = ' ') do Dec(i);
  TrimTrailingSpaces := Copy(s, 1, i);
end;

procedure DrawDialogFrame;
var i: Integer;
begin
  TextColor(Black); TextBackground(LightGray);
  for i := 6 to 19 do 
  begin 
    GotoXY(8, i); 
    WriteChars(' ', 64); 
  end;
  
  TextBackground(DarkGray);
  for i := 7 to 20 do 
  begin 
    GotoXY(72, i); 
    WriteChars(' ', 2); 
  end;
  
  GotoXY(10, 20); 
  WriteChars(' ', 64);
end;

procedure RestoreUIColors;
begin
  TextColor(White); 
  TextBackground(Blue);
end;

procedure DrawUI;
var MenuBarText: string;
begin
  CurrentAttr := $1F; ClrScr;
  GotoXY(1, 1); 
  TextColor(Black); 
  TextBackground(LightGray);
  
  MenuBarText := ' FLED [F1] New [F2] Open [F3] Save [F4] Search [F5] Comp [F6] Hex [ESC] Exit ';
  Print(MenuBarText);
  if Length(MenuBarText) < 80 then 
    WriteChars(' ', 80 - Length(MenuBarText));
    
  RestoreUIColors;
end;

procedure DrawStatusBar;
begin
  GotoXY(1, 25);
  TextColor(Black); TextBackground(LightGray);
  if File1Name = '' then 
    Print(' Editing: UNTITLED                                                           ')
  else 
  begin 
    Print(' Editing: ' + File1Name); 
    WriteChars(' ', 80 - 10 - Length(File1Name)); 
  end;
  RestoreUIColors;
end;

procedure RedrawTextViewport;
var i, ScreenY: Integer; LineToPrint: string;
begin
  for ScreenY := 1 to VIEWPORT_HEIGHT do
  begin
    GotoXY(1, ScreenY + 1);
    TextColor(White); TextBackground(Blue);
    if (ScrollTopY + ScreenY - 1) <= MAX_LINES then
    begin
      LineToPrint := GetLine(ScrollTopY + ScreenY - 1);
      Print(LineToPrint);
      if Length(LineToPrint) < 80 then 
        WriteChars(' ', 80 - Length(LineToPrint));
    end 
    else 
      WriteChars(' ', 80);
  end;
  
  DrawStatusBar;
end;

procedure UpdateCursor;
begin
  GotoXY(CursorAbsX, CursorAbsY - ScrollTopY + 2);
end;

procedure LoadDirIntoMemory;
var SR: SearchRec;
begin
  FileCount := 0;
  FindFirst('*.*', AnyFile, SR);
  while (DosError = 0) and (FileCount < MAX_DIR_FILES) do
  begin
    if (SR.Name <> '.') and ((SR.Attr and VolumeID) = 0) then
    begin
      Inc(FileCount);
      if (SR.Attr and Directory) <> 0 then 
        FileList[FileCount] := '[' + SR.Name + ']'
      else 
        FileList[FileCount] := SR.Name;
    end;
    FindNext(SR);
  end;
end;

procedure DrawFileList(ScrollTop: Integer);
var i, Row, Col, DrawCount: Integer;
begin
  TextColor(Black); TextBackground(LightGray);
  for i := 13 to 18 do 
  begin 
    GotoXY(10, i); 
    WriteChars(' ', 60); 
  end;
  
  if FileCount = 0 then Exit;
  
  DrawCount := FileCount - ScrollTop;
  if DrawCount > 24 then DrawCount := 24;
  
  for i := 1 to DrawCount do
  begin
    Row := ((i - 1) shr 2) + 13;
    Col := ((i - 1) and 3) * 15 + 10;
    GotoXY(Col, Row);
    
    if (ScrollTop + i - 1) = SelectedFile then 
    begin 
      TextColor(White); 
      TextBackground(Blue); 
    end
    else 
    begin 
      TextColor(Black); 
      TextBackground(LightGray); 
    end;
    
    Print(FileList[ScrollTop + i]);
  end;
  RestoreUIColors;
end;

function GetFilenameGrid(Prompt: string): string;
var ch: Char; Done: Boolean; TempName, DirName: string; FileScrollTop: Integer;
begin
  CursorOff; DrawDialogFrame;
  TextColor(Black); TextBackground(LightGray);
  GotoXY(10, 7); Print(Prompt);
  GotoXY(10, 11); Print(msg_avail);
  LoadDirIntoMemory; SelectedFile := 0; FileScrollTop := 0; Done := false;
  
  repeat
    DrawFileList(FileScrollTop);
    ch := ReadKey;
    if ch = #0 then
    begin
      ch := ReadKey;
      case ch of
        #72: 
          if SelectedFile >= 4 then 
          begin 
            Dec(SelectedFile, 4); 
            if SelectedFile < FileScrollTop then Dec(FileScrollTop, 4); 
          end;
        #80: 
          if SelectedFile + 4 < FileCount then 
          begin 
            Inc(SelectedFile, 4); 
            if SelectedFile >= FileScrollTop + 24 then Inc(FileScrollTop, 4); 
          end;
        #75: 
          if SelectedFile > 0 then 
          begin 
            Dec(SelectedFile); 
            if SelectedFile < FileScrollTop then Dec(FileScrollTop, 4); 
          end;
        #77: 
          if SelectedFile + 1 < FileCount then 
          begin 
            Inc(SelectedFile); 
            if SelectedFile >= FileScrollTop + 24 then Inc(FileScrollTop, 4); 
          end;
        #73: 
          begin 
            if SelectedFile >= 24 then Dec(SelectedFile, 24) else SelectedFile := 0; 
            if FileScrollTop >= 24 then Dec(FileScrollTop, 24) else FileScrollTop := 0; 
          end;
        #81: 
          begin 
            if SelectedFile + 24 < FileCount then Inc(SelectedFile, 24) 
            else SelectedFile := FileCount - 1; 
            
            FileScrollTop := (SelectedFile shr 2) shl 2 - 20; 
            if FileScrollTop < 0 then FileScrollTop := 0; 
          end;
      end;
    end
    else if ch = #27 then 
    begin 
      GetFilenameGrid := ''; Done := true; 
    end
    else if ch = #13 then
    begin
      if FileCount > 0 then
      begin
        TempName := FileList[SelectedFile + 1];
        if (Length(TempName) > 2) and (TempName[1] = '[') and 
           (TempName[Length(TempName)] = ']') then
        begin
          DirName := Copy(TempName, 2, Length(TempName) - 2);
          {$I-} ChDir(DirName); {$I+}
          if IOResult = 0 then 
          begin 
            LoadDirIntoMemory; SelectedFile := 0; FileScrollTop := 0; 
          end;
        end 
        else 
        begin 
          GetFilenameGrid := TempName; Done := true; 
        end;
      end 
      else 
      begin 
        GetFilenameGrid := ''; Done := true; 
      end;
    end;
  until Done;
  RestoreUIColors; CursorOn;
end;

function GetFilenameTyping(Prompt: string): string;
var InputStr: string; ch: Char; Done: Boolean;
begin
  DrawDialogFrame; TextColor(Black); TextBackground(LightGray);
  GotoXY(10, 7); Print(Prompt); GotoXY(10, 9); Print(' > ');
  InputStr := ''; Done := false; CursorOn;
  
  repeat
    GotoXY(13 + Length(InputStr), 9);
    ch := ReadKey;
    if ch = #13 then 
      Done := true
    else if ch = #27 then 
    begin 
      InputStr := ''; Done := true; 
    end
    else if ch = #8 then 
    begin 
      if Length(InputStr) > 0 then 
      begin 
        InputStr[0] := Char(Length(InputStr) - 1); 
        GotoXY(13 + Length(InputStr), 9); 
        Print(' '); 
      end; 
    end
    else if (ch >= #32) and (ch <= #255) and (Length(InputStr) < 40) then 
    begin 
      InputStr := InputStr + ch; Print(ch); 
    end;
  until Done;
  
  CursorOff; GetFilenameTyping := InputStr; RestoreUIColors; CursorOn;
end;

function GetFilenameSave(Prompt: string): string;
var ch: Char; Done: Boolean; TempName, DirName, InputStr: string; FileScrollTop: Integer;
begin
  CursorOff; DrawDialogFrame;
  TextColor(Black); TextBackground(LightGray);
  GotoXY(10, 7); Print(Prompt);
  GotoXY(10, 11); Print(msg_avail);
  LoadDirIntoMemory; SelectedFile := 0; FileScrollTop := 0; Done := false;
  InputStr := '';
  
  repeat
    DrawFileList(FileScrollTop);
    
    { Draw input line }
    GotoXY(10, 9); TextColor(Black); TextBackground(LightGray);
    Print(' > ' + InputStr);
    WriteChars(' ', 60 - 3 - Length(InputStr)); { Clear remainder of line visually }
    GotoXY(13 + Length(InputStr), 9);
    CursorOn;
    
    ch := ReadKey;
    if ch = #0 then
    begin
      CursorOff;
      ch := ReadKey;
      case ch of
        #72: 
          if SelectedFile >= 4 then 
          begin 
            Dec(SelectedFile, 4); 
            if SelectedFile < FileScrollTop then Dec(FileScrollTop, 4); 
          end;
        #80: 
          if SelectedFile + 4 < FileCount then 
          begin 
            Inc(SelectedFile, 4); 
            if SelectedFile >= FileScrollTop + 24 then Inc(FileScrollTop, 4); 
          end;
        #75: 
          if SelectedFile > 0 then 
          begin 
            Dec(SelectedFile); 
            if SelectedFile < FileScrollTop then Dec(FileScrollTop, 4); 
          end;
        #77: 
          if SelectedFile + 1 < FileCount then 
          begin 
            Inc(SelectedFile); 
            if SelectedFile >= FileScrollTop + 24 then Inc(FileScrollTop, 4); 
          end;
        #73: 
          begin 
            if SelectedFile >= 24 then Dec(SelectedFile, 24) else SelectedFile := 0; 
            if FileScrollTop >= 24 then Dec(FileScrollTop, 24) else FileScrollTop := 0; 
          end;
        #81: 
          begin 
            if SelectedFile + 24 < FileCount then Inc(SelectedFile, 24) 
            else SelectedFile := FileCount - 1; 
            FileScrollTop := (SelectedFile shr 2) shl 2 - 20; 
            if FileScrollTop < 0 then FileScrollTop := 0; 
          end;
      end;
    end
    else if ch = #27 then 
    begin 
      GetFilenameSave := ''; Done := true; 
    end
    else if ch = #8 then 
    begin 
      if Length(InputStr) > 0 then Dec(InputStr[0]); 
    end
    else if ch = #13 then
    begin
      if Length(InputStr) > 0 then
      begin
        GetFilenameSave := InputStr; Done := true;
      end
      else if FileCount > 0 then
      begin
        TempName := FileList[SelectedFile + 1];
        if (Length(TempName) > 2) and (TempName[1] = '[') and 
           (TempName[Length(TempName)] = ']') then
        begin
          DirName := Copy(TempName, 2, Length(TempName) - 2);
          {$I-} ChDir(DirName); {$I+}
          if IOResult = 0 then 
          begin 
            LoadDirIntoMemory; SelectedFile := 0; FileScrollTop := 0; InputStr := ''; 
          end;
        end 
        else 
        begin 
          GetFilenameSave := TempName; Done := true; 
        end;
      end;
    end
    else if (ch >= #32) and (ch <= #255) and (Length(InputStr) < 40) then 
    begin 
      InputStr := InputStr + ch; 
    end;
  until Done;
  
  CursorOff; RestoreUIColors; CursorOn;
end;

{ Pure binary-safe loader. Completely ignores ^Z/EOF text markers }
procedure LoadTextFile(FileName: string);
var
  F: file;
  Buffer: array[1..4096] of Byte;
  BytesRead, i: Word;
  TempLine: string;
  b: Byte;
begin
  InitTextBuffer;
  CursorAbsX := 1; CursorAbsY := 1; ScrollTopY := 1;
  
  Assign(F, FileName);
  {$I-} Reset(F, 1); {$I+} 
  if IOResult <> 0 then Exit;
  
  TempLine := '';
  while (not System.EOF(F)) and (CursorAbsY <= MAX_LINES) do
  begin
    BlockRead(F, Buffer, SizeOf(Buffer), BytesRead);
    if BytesRead = 0 then Break;
    
    for i := 1 to BytesRead do
    begin
      b := Buffer[i];
      if b = 13 then Continue; { Visually ignore CR }
      
      if b = 10 then
      begin
        SetLine(CursorAbsY, TempLine);
        Inc(CursorAbsY);
        TempLine := '';
        if CursorAbsY > MAX_LINES then Break;
      end
      else
      begin
        TempLine := TempLine + Char(b);
        if Length(TempLine) = 80 then
        begin
          SetLine(CursorAbsY, TempLine);
          Inc(CursorAbsY);
          TempLine := '';
          if CursorAbsY > MAX_LINES then Break;
        end;
      end;
    end;
  end;
  
  if (TempLine <> '') and (CursorAbsY <= MAX_LINES) then
  begin
    SetLine(CursorAbsY, TempLine);
    Inc(CursorAbsY);
  end;
  
  Close(F);
  CursorAbsX := 1; CursorAbsY := 1; ScrollTopY := 1;
  RedrawTextViewport;
end;

procedure DoNew;
begin
  InitTextBuffer;
  File1Name := '';
  File2Name := '';
  CursorAbsX := 1; CursorAbsY := 1; ScrollTopY := 1;
  RedrawTextViewport;
end;

{ Safe untyped binary export }
procedure DoSave;
var
  FOut: file;
  i, LastActiveRow: Integer;
  s: string;
  CRLF: array[1..2] of Byte;
begin
  if File1Name = '' then
  begin
    File1Name := GetFilenameSave(prompt_save);
    RedrawTextViewport;
    if File1Name = '' then Exit;
  end;
  
  Assign(FOut, File1Name);
  {$I-} Rewrite(FOut, 1); {$I+}
  if IOResult <> 0 then Exit;
  
  CRLF[1] := 13; CRLF[2] := 10;
  LastActiveRow := 0;
  for i := MAX_LINES downto 1 do
  begin
    if TrimTrailingSpaces(GetLine(i)) <> '' then
    begin
      LastActiveRow := i;
      Break;
    end;
  end;
  
  if LastActiveRow > 0 then
  begin
    for i := 1 to LastActiveRow do
    begin
      s := TrimTrailingSpaces(GetLine(i));
      if Length(s) > 0 then BlockWrite(FOut, s[1], Length(s));
      BlockWrite(FOut, CRLF, 2);
    end;
  end;
      
  Close(FOut);
  
  GotoXY(1, 25); TextColor(Black); TextBackground(LightGreen);
  Print(' Successfully saved ' + File1Name + ' ');
  WriteChars(' ', 80 - 21 - Length(File1Name));
  RestoreUIColors;
  ResetStatus := True;
end;

procedure DoSearch;
var
  SearchStr: string;
  Found: Boolean;
  SearchRow, SearchCol, ColPos: Integer;
  ch: Char;
begin
  SearchStr := GetFilenameTyping(prompt_search);
  if SearchStr = '' then begin RedrawTextViewport; Exit; end;
  
  SearchRow := 1; SearchCol := 1;
  
  repeat
    Found := false;
    while (SearchRow <= MAX_LINES) and (not Found) do
    begin
      ColPos := Pos(SearchStr, Copy(GetLine(SearchRow), SearchCol, 80));
      if ColPos > 0 then
      begin
        Found := true; CursorAbsY := SearchRow;
        CursorAbsX := SearchCol + ColPos - 1;
        SearchCol := CursorAbsX + 1;
      end
      else 
      begin 
        Inc(SearchRow); SearchCol := 1; 
      end;
    end;
    
    if Found then
    begin
      if CursorAbsY < ScrollTopY then 
        ScrollTopY := CursorAbsY
      else if CursorAbsY >= ScrollTopY + VIEWPORT_HEIGHT then 
        ScrollTopY := CursorAbsY - VIEWPORT_HEIGHT + 1;
        
      RedrawTextViewport;
      
      GotoXY(CursorAbsX, CursorAbsY - ScrollTopY + 2);
      TextColor(Black); TextBackground(LightCyan); 
      Print(SearchStr); RestoreUIColors;
      
      GotoXY(1, 25); TextColor(Black); TextBackground(LightGray);
      Print(' Search Mode: Press ''N'' for next match, ESC to exit... '); 
      WriteChars(' ', 80 - 55); RestoreUIColors;
      
      repeat
        ch := ReadKey; if ch = #0 then ReadKey;
      until (UpCase(ch) = 'N') or (ch = #27);
      
      if ch = #27 then Break;
    end
    else
    begin
      GotoXY(1, 25); TextColor(White); TextBackground(LightRed);
      Print(' ' + msg_not_found + ' Press ESC. '); 
      WriteChars(' ', 80 - Length(msg_not_found) - 14); RestoreUIColors;
      repeat ch := ReadKey until ch = #27; 
      Break;
    end;
  until false;
  
  RedrawTextViewport;
end;

function ByteToHex(b: Byte): string;
var s: string[2];
begin
  s[0] := #2; 
  s[1] := hex_digits[(b shr 4) + 1]; 
  s[2] := hex_digits[(b and $0F) + 1]; 
  ByteToHex := s;
end;

function LongIntToHex(L: LongInt): string;
begin
  LongIntToHex := ByteToHex(Byte((L shr 24) and $FF)) + 
                  ByteToHex(Byte((L shr 16) and $FF)) +
                  ByteToHex(Byte((L shr 8) and $FF)) + 
                  ByteToHex(Byte(L and $FF));
end;

procedure DoHex;
label
  SkipHexSave;
var
  F, FTemp, FOut: file;
  b: Byte; Block: array[0..15] of Byte; BytesRead: Word;
  Line, i, LastActiveRow: Integer; FSize, HexScrollTop: LongInt;
  HexCursorX, HexCursorY, HexNibble: Integer; s: string;
  CRLF: array[1..2] of Byte;
  ch, ActionKey: Char; Done, NeedsRedraw, ShowSaveSuccess: Boolean; Val: Byte;
  OldHexCursorX, OldHexCursorY: Integer;
  ScreenBuf: array[0..21, 0..15] of Byte;
  ScreenBytes: array[0..21] of Integer;
  
  { Variables added to shift bytes for Insert/Delete }
  CurrOffset, ShiftPos: LongInt;
  ShiftRead: Word;
  ShiftBuf: array[1..4096] of Byte;
begin
  Assign(FTemp, 'FLED$$$.TMP');
  {$I-} Rewrite(FTemp, 1); {$I+}
  if IOResult = 0 then
  begin
    CRLF[1] := 13; CRLF[2] := 10;
    LastActiveRow := 0;
    for i := MAX_LINES downto 1 do
      if TrimTrailingSpaces(GetLine(i)) <> '' then 
      begin 
        LastActiveRow := i; Break; 
      end;
      
    if LastActiveRow > 0 then
      for i := 1 to LastActiveRow do
      begin
        s := TrimTrailingSpaces(GetLine(i));
        if Length(s) > 0 then BlockWrite(FTemp, s[1], Length(s));
        BlockWrite(FTemp, CRLF, 2);
      end;
    Close(FTemp);
  end;
  
  Assign(F, 'FLED$$$.TMP');
  {$I-} Reset(F, 1); {$I+}
  if IOResult <> 0 then Exit;
  
  FSize := FileSize(F); HexScrollTop := 0; HexCursorX := 0; HexCursorY := 0; 
  HexNibble := 0; Done := false; NeedsRedraw := true; ShowSaveSuccess := false; CursorOff;
  OldHexCursorX := 0; OldHexCursorY := 0; ActionKey := #0;
  
  repeat
    if NeedsRedraw then
    begin
      DrawUI; GotoXY(1, 2); TextColor(Yellow); 
      PrintLn('Offset    00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F  ASCII'); 
      TextColor(White);
      Seek(F, HexScrollTop);
      
      for Line := 0 to 21 do ScreenBytes[Line] := 0;
      
      for Line := 0 to 21 do
      begin
        if System.EOF(F) then Break;
        BlockRead(F, Block, 16, BytesRead);
        ScreenBytes[Line] := BytesRead;
        if BytesRead = 0 then Break;
        for i := 0 to BytesRead - 1 do ScreenBuf[Line, i] := Block[i];
        
        GotoXY(1, Line + 3);
        Print(LongIntToHex(HexScrollTop + (Line * 16)) + '  ');
        
        for i := 0 to 15 do
        begin
          if (i = HexCursorX) and (Line = HexCursorY) then 
          begin 
            TextColor(Black); TextBackground(LightGray); 
          end;
          if i < BytesRead then Print(ByteToHex(Block[i])) else Print('  ');
          TextColor(White); TextBackground(Blue); Print(' ');
        end;
        
        Print('| ');
        for i := 0 to 15 do
        begin
          if i < BytesRead then 
          begin 
            if Block[i] in [32..255] then Print(Char(Block[i])) else Print('.'); 
          end 
          else Print(' ');
        end;
      end;
      
      GotoXY(1, 25); TextColor(Black); TextBackground(LightGray);
      Print(' Hex Edit: Arrows nav, 0-9/A-F type, Ins add, Del rm, PgUp/Dn, ESC exits '); 
      WriteChars(' ', 80 - 73); RestoreUIColors;
      NeedsRedraw := false;
    end
    else
    begin
      if (OldHexCursorX <> HexCursorX) or (OldHexCursorY <> HexCursorY) then
      begin
        GotoXY(11 + OldHexCursorX * 3, OldHexCursorY + 3);
        TextColor(White); TextBackground(Blue);
        if OldHexCursorX < ScreenBytes[OldHexCursorY] then 
          Print(ByteToHex(ScreenBuf[OldHexCursorY, OldHexCursorX]))
        else Print('  ');
        
        GotoXY(11 + HexCursorX * 3, HexCursorY + 3);
        TextColor(Black); TextBackground(LightGray);
        if HexCursorX < ScreenBytes[HexCursorY] then 
          Print(ByteToHex(ScreenBuf[HexCursorY, HexCursorX]))
        else Print('  ');
      end;
    end;
    
    if ShowSaveSuccess then
    begin
      GotoXY(1, 25); TextColor(Black); TextBackground(LightGreen);
      Print(' Successfully saved ' + File1Name + ' ');
      WriteChars(' ', 80 - 21 - Length(File1Name));
      RestoreUIColors;
      ShowSaveSuccess := false;
      ResetStatus := True;
    end;
    
    OldHexCursorX := HexCursorX; OldHexCursorY := HexCursorY;
    GotoXY(11 + HexCursorX * 3 + HexNibble, HexCursorY + 3); CursorOn;
    ch := ReadKey; CursorOff;
    
    if ResetStatus then
    begin
      ResetStatus := False;
      GotoXY(1, 25); TextColor(Black); TextBackground(LightGray);
      Print(' Hex Edit: Arrows nav, 0-9/A-F type, Ins add, Del rm, PgUp/Dn, ESC exits '); 
      WriteChars(' ', 80 - 73); RestoreUIColors;
    end;
    
    if ch = #0 then
    begin
      ch := ReadKey;
      case ch of
        #59: { F1 New within Hex }
          begin
            File1Name := ''; File2Name := '';
            Close(F);
            Assign(FTemp, 'FLED$$$.TMP'); {$I-} Rewrite(FTemp, 1); {$I+} Close(FTemp);
            Assign(F, 'FLED$$$.TMP'); Reset(F, 1);
            FSize := 0; HexScrollTop := 0; HexCursorX := 0; HexCursorY := 0; HexNibble := 0;
            OldHexCursorX := 0; OldHexCursorY := 0; NeedsRedraw := true;
            InitTextBuffer; CursorAbsX := 1; CursorAbsY := 1; ScrollTopY := 1;
          end;
        #60: { F2 Open within Hex }
          begin
            s := GetFilenameGrid(prompt_open1);
            if s <> '' then
            begin
              File1Name := s; Close(F); LoadTextFile(File1Name);
              Assign(FTemp, 'FLED$$$.TMP'); Rewrite(FTemp, 1);
              CRLF[1] := 13; CRLF[2] := 10; LastActiveRow := 0;
              for i := MAX_LINES downto 1 do
                if TrimTrailingSpaces(GetLine(i)) <> '' then begin LastActiveRow := i; Break; end;
              if LastActiveRow > 0 then
                for i := 1 to LastActiveRow do
                begin
                  s := TrimTrailingSpaces(GetLine(i));
                  if Length(s) > 0 then BlockWrite(FTemp, s[1], Length(s));
                  BlockWrite(FTemp, CRLF, 2);
                end;
              Close(FTemp);
              Assign(F, 'FLED$$$.TMP'); Reset(F, 1); FSize := FileSize(F);
              HexScrollTop := 0; HexCursorX := 0; HexCursorY := 0; HexNibble := 0;
              OldHexCursorX := 0; OldHexCursorY := 0;
            end;
            NeedsRedraw := true;
          end;
        #61: { F3 Save within Hex }
          begin
            if File1Name = '' then
            begin
              s := GetFilenameSave(prompt_save);
              NeedsRedraw := true;
              if s = '' then goto SkipHexSave;
              File1Name := s;
            end;
            Close(F);
            Assign(FTemp, 'FLED$$$.TMP'); Reset(FTemp, 1);
            Assign(FOut, File1Name); {$I-} Rewrite(FOut, 1); {$I+}
            if IOResult = 0 then
            begin
              repeat
                BlockRead(FTemp, ScreenBuf, SizeOf(ScreenBuf), BytesRead);
                if BytesRead > 0 then BlockWrite(FOut, ScreenBuf, BytesRead);
              until BytesRead = 0;
              Close(FOut);
              ShowSaveSuccess := true;
            end;
            Close(FTemp);
            Assign(F, 'FLED$$$.TMP'); Reset(F, 1);
          SkipHexSave:
          end;
        #62, #63: 
          begin 
            ActionKey := ch; Done := true; 
          end;
        #64: Done := true; { F6 inside Hex mode safely exits back to text mode }
        #72: 
          if HexCursorY > 0 then Dec(HexCursorY) 
          else if HexScrollTop >= 16 then 
          begin 
            Dec(HexScrollTop, 16); NeedsRedraw := true; 
          end;
        #80: 
          if HexCursorY < 21 then Inc(HexCursorY) 
          else if HexScrollTop + 16 < FSize then 
          begin 
            Inc(HexScrollTop, 16); NeedsRedraw := true; 
          end;
        #75: 
          begin 
            if HexNibble = 1 then HexNibble := 0 
            else if HexCursorX > 0 then 
            begin 
              Dec(HexCursorX); HexNibble := 1; 
            end 
            else if HexCursorY > 0 then 
            begin 
              Dec(HexCursorY); HexCursorX := 15; HexNibble := 1; 
            end 
            else if HexScrollTop >= 16 then 
            begin 
              Dec(HexScrollTop, 16); HexCursorX := 15; HexNibble := 1; NeedsRedraw := true; 
            end; 
          end;
        #77: 
          begin 
            if HexNibble = 0 then HexNibble := 1 
            else if HexCursorX < 15 then 
            begin 
              Inc(HexCursorX); HexNibble := 0; 
            end 
            else if HexCursorY < 21 then 
            begin 
              Inc(HexCursorY); HexCursorX := 0; HexNibble := 0; 
            end 
            else if HexScrollTop + 16 < FSize then 
            begin 
              Inc(HexScrollTop, 16); HexCursorX := 0; HexNibble := 0; NeedsRedraw := true; 
            end; 
          end;
        #73: 
          if HexScrollTop >= 16 * 22 then 
          begin 
            Dec(HexScrollTop, 16 * 22); NeedsRedraw := true; 
          end 
          else if HexScrollTop > 0 then 
          begin 
            HexScrollTop := 0; NeedsRedraw := true; 
          end;
        #81: 
          if HexScrollTop + (16 * 22) < FSize then 
          begin 
            Inc(HexScrollTop, 16 * 22); NeedsRedraw := true; 
          end;
          
        { --- NEW: Insert byte shift logic --- }
        #82: { Insert Key }
          begin
            CurrOffset := HexScrollTop + HexCursorY * 16 + HexCursorX;
            if CurrOffset <= FSize then
            begin
              ShiftPos := FSize;
              while ShiftPos > CurrOffset do
              begin
                if ShiftPos - CurrOffset > 4096 then ShiftRead := 4096
                else ShiftRead := ShiftPos - CurrOffset;
                
                Seek(F, ShiftPos - ShiftRead);
                BlockRead(F, ShiftBuf, ShiftRead);
                Seek(F, ShiftPos - ShiftRead + 1);
                BlockWrite(F, ShiftBuf, ShiftRead);
                Dec(ShiftPos, ShiftRead);
              end;
              
              Seek(F, CurrOffset);
              b := 0; { Initialize new space with 00 }
              BlockWrite(F, b, 1);
              Inc(FSize);
              NeedsRedraw := true;
            end;
          end;
          
        { --- NEW: Delete byte shift logic --- }
        #83: { Delete Key }
          begin
            CurrOffset := HexScrollTop + HexCursorY * 16 + HexCursorX;
            if CurrOffset < FSize then
            begin
              ShiftPos := CurrOffset + 1;
              while ShiftPos < FSize do
              begin
                if FSize - ShiftPos > 4096 then ShiftRead := 4096
                else ShiftRead := FSize - ShiftPos;
                
                Seek(F, ShiftPos);
                BlockRead(F, ShiftBuf, ShiftRead);
                Seek(F, ShiftPos - 1);
                BlockWrite(F, ShiftBuf, ShiftRead);
                Inc(ShiftPos, ShiftRead);
              end;
              
              Dec(FSize);
              Seek(F, FSize);
              Truncate(F);
              NeedsRedraw := true;
            end;
          end;
      end;
    end
    else if ch = #27 then Done := true
    else
    begin
      ch := UpCase(ch);
      if ((ch >= '0') and (ch <= '9')) or ((ch >= 'A') and (ch <= 'F')) then
      begin
        if ch <= '9' then Val := Ord(ch) - 48 else Val := Ord(ch) - 55;
        if HexScrollTop + HexCursorY * 16 + HexCursorX < FSize then
        begin
          Seek(F, HexScrollTop + HexCursorY * 16 + HexCursorX); 
          BlockRead(F, b, 1);
          
          if HexNibble = 0 then b := Byte((b and $0F) or (Val shl 4)) 
          else b := Byte((b and $F0) or Val);
          
          Seek(F, HexScrollTop + HexCursorY * 16 + HexCursorX); 
          BlockWrite(F, b, 1);
          
          ScreenBuf[HexCursorY, HexCursorX] := b;
          GotoXY(11 + HexCursorX * 3, HexCursorY + 3);
          TextColor(Black); TextBackground(LightGray);
          Print(ByteToHex(b));
          
          GotoXY(61 + HexCursorX, HexCursorY + 3);
          TextColor(White); TextBackground(Blue);
          if b in [32..255] then Print(Char(b)) else Print('.');
          
          if HexNibble = 0 then HexNibble := 1 
          else 
          begin 
            HexNibble := 0; 
            if HexCursorX < 15 then Inc(HexCursorX) 
            else if HexCursorY < 21 then 
            begin 
              Inc(HexCursorY); HexCursorX := 0; 
            end 
            else if HexScrollTop + 16 < FSize then 
            begin 
              Inc(HexScrollTop, 16); HexCursorX := 0; NeedsRedraw := true; 
            end; 
          end;
        end;
      end;
    end;
  until Done;
  
  Close(F);
  LoadTextFile('FLED$$$.TMP');
  
  Assign(FTemp, 'FLED$$$.TMP');
  {$I-} Erase(FTemp); {$I+}
  
  CursorOn;
  
  { Safe trigger for F4, F5 pressed during Hex Mode }
  if ActionKey <> #0 then
  begin
    RedrawTextViewport;
    case ActionKey of
      #62: DoSearch;
      #63: DoCompare;
    end;
  end;
end;

procedure DoCompare;
var
  F1, F2: file; Buf1, Buf2: array[0..31] of Byte; PreBuf1, PreBuf2: array[1..512] of Byte;
  Read1, Read2: Word; DiffScrollTop, MaxSize, FSize1, FSize2, CurrOffset: LongInt;
  i, Line, ViewMode, BytesPerLine: Integer; ch, ActionKey: Char; Done, FilesMatch: Boolean; 
  InfoStr, ModeName: string;
begin
  if File1Name = '' then
  begin
    File1Name := GetFilenameGrid(prompt_open1); 
    RedrawTextViewport; 
    if File1Name = '' then Exit;
  end;
  
  File2Name := GetFilenameGrid(prompt_open2); 
  RedrawTextViewport; 
  if File2Name = '' then Exit;
  
  Assign(F1, File1Name); Assign(F2, File2Name);
  {$I-} Reset(F1, 1); Reset(F2, 1); {$I+}
  if IOResult <> 0 then Exit;
  
  FSize1 := FileSize(F1); FSize2 := FileSize(F2); 
  FilesMatch := (FSize1 = FSize2);
  
  if FilesMatch then
  begin
    while not System.EOF(F1) do
    begin
      BlockRead(F1, PreBuf1, SizeOf(PreBuf1), Read1); 
      BlockRead(F2, PreBuf2, SizeOf(PreBuf2), Read2);
      for i := 1 to Read1 do 
        if PreBuf1[i] <> PreBuf2[i] then 
        begin 
          FilesMatch := false; Break; 
        end;
      if not FilesMatch then Break;
    end;
  end;
  
  if FilesMatch then
  begin
    GotoXY(1, 25); TextColor(Black); TextBackground(LightGreen); 
    Print(' ' + msg_match + ' Press any key to return... '); 
    WriteChars(' ', 80 - Length(msg_match) - 29); RestoreUIColors;
    ch := ReadKey; if ch = #0 then ReadKey;
    Close(F1); Close(F2); RedrawTextViewport; Exit;
  end;
  
  Seek(F1, 0); Seek(F2, 0); 
  if FSize1 > FSize2 then MaxSize := FSize1 else MaxSize := FSize2;
  
  DiffScrollTop := 0; ViewMode := 0; Done := false; CursorOff; ActionKey := #0;
  
  repeat
    if ViewMode = 2 then BytesPerLine := 30 else BytesPerLine := 8;
    DrawUI; GotoXY(1, 2); TextColor(Yellow);
    if ViewMode = 0 then 
      PrintLn('Offset   | - File 1 (Hex)           | + File 2 (Hex)           | ASCII Diff')
    else if ViewMode = 1 then 
      PrintLn('Offset   | - File 1 (Hex Only)      | + File 2 (Hex Only)')
    else 
      PrintLn('Offset   | - File 1 (ASCII)                | + File 2 (ASCII)');
    TextColor(White);
    
    for Line := 0 to 21 do
    begin
      CurrOffset := DiffScrollTop + (Line * BytesPerLine);
      if CurrOffset >= MaxSize then Break;
      
      if CurrOffset < FSize1 then 
      begin 
        Seek(F1, CurrOffset); BlockRead(F1, Buf1, BytesPerLine, Read1); 
      end else Read1 := 0;
      
      if CurrOffset < FSize2 then 
      begin 
        Seek(F2, CurrOffset); BlockRead(F2, Buf2, BytesPerLine, Read2); 
      end else Read2 := 0;
      
      Print(LongIntToHex(CurrOffset) + ' | ');
      if ViewMode in [0, 1] then
      begin
        TextColor(LightCyan); Print('- ');
        for i := 0 to BytesPerLine - 1 do 
        begin 
          if i < Read1 then 
          begin 
            if (i < Read2) and (Buf1[i] <> Buf2[i]) then 
              TextColor(LightRed) 
            else 
              TextColor(LightCyan); 
            Print(ByteToHex(Buf1[i]) + ' '); 
          end else Print('   '); 
        end; 
        TextColor(White); Print('| ');
        
        TextColor(LightGreen); Print('+ ');
        for i := 0 to BytesPerLine - 1 do 
        begin 
          if i < Read2 then 
          begin 
            if (i < Read1) and (Buf1[i] <> Buf2[i]) then 
              TextColor(LightRed) 
            else 
              TextColor(LightGreen); 
            Print(ByteToHex(Buf2[i]) + ' '); 
          end else Print('   '); 
        end;
        
        if ViewMode = 0 then 
        begin 
          TextColor(White); Print('| '); 
        end;
      end;
      
      if ViewMode = 0 then
      begin
        for i := 0 to BytesPerLine - 1 do 
        begin 
          if (i < Read1) and (i < Read2) and (Buf1[i] <> Buf2[i]) then 
            TextColor(LightRed) 
          else 
            TextColor(White); 
            
          if (i < Read1) and (Buf1[i] in [32..255]) then 
            Print(Char(Buf1[i])) 
          else if (i < Read2) and (Buf2[i] in [32..255]) then 
            Print(Char(Buf2[i])) 
          else Print('.'); 
        end;
      end
      else if ViewMode = 2 then
      begin
        TextColor(LightCyan); Print('- ');
        for i := 0 to BytesPerLine - 1 do 
        begin 
          if i < Read1 then 
          begin 
            if (i < Read2) and (Buf1[i] <> Buf2[i]) then 
              TextColor(LightRed) 
            else 
              TextColor(LightCyan); 
              
            if Buf1[i] in [32..255] then 
              Print(Char(Buf1[i])) 
            else Print(' '); 
          end else Print(' '); 
        end; 
        TextColor(White); Print(' | ');
        
        TextColor(LightGreen); Print('+ ');
        for i := 0 to BytesPerLine - 1 do 
        begin 
          if i < Read2 then 
          begin 
            if (i < Read1) and (Buf1[i] <> Buf2[i]) then 
              TextColor(LightRed) 
            else 
              TextColor(LightGreen); 
              
            if Buf2[i] in [32..255] then 
              Print(Char(Buf2[i])) 
            else Print(' '); 
          end else Print(' '); 
        end;
      end;
      PrintLn('');
    end;
    
    GotoXY(1, 25); TextColor(Black); TextBackground(LightGray);
    case ViewMode of 
      0: ModeName := 'Combined'; 
      1: ModeName := 'Hex Only'; 
      2: ModeName := 'ASCII Only'; 
    end;
    
    InfoStr := ' Diff [' + ModeName + ']: Arrows/PgUp/Dn scroll. [F7] Toggle Mode. [ESC] Exit. ';
    Print(InfoStr); WriteChars(' ', 80 - Length(InfoStr)); RestoreUIColors;
    
    ch := ReadKey;
    if ch = #0 then
    begin
      ch := ReadKey;
      case ch of
        #59..#62, #64: 
          begin 
            ActionKey := ch; Done := true; 
          end;
        #63: Done := true; { F5 inside Compare safely exits }
        #72: 
          if DiffScrollTop >= BytesPerLine then Dec(DiffScrollTop, BytesPerLine);
        #80: 
          if DiffScrollTop + BytesPerLine < MaxSize then Inc(DiffScrollTop, BytesPerLine);
        #73: 
          if DiffScrollTop >= BytesPerLine * 22 then Dec(DiffScrollTop, BytesPerLine * 22) 
          else DiffScrollTop := 0;
        #81: 
          if DiffScrollTop + (BytesPerLine * 22) < MaxSize then Inc(DiffScrollTop, BytesPerLine * 22);
        #65: 
          if ViewMode = 2 then ViewMode := 0 else Inc(ViewMode); { F7 }
      end;
    end else if ch = #27 then Done := true;
  until Done;
  
  Close(F1); Close(F2); CursorOn; RedrawTextViewport;
  
  { Safe trigger for F1-F4, F6 pressed during Compare Mode }
  if ActionKey <> #0 then
  begin
    case ActionKey of
      #59: DoNew;
      #60: 
        begin 
          File1Name := GetFilenameGrid(prompt_open1); 
          RedrawTextViewport; 
          if File1Name <> '' then LoadTextFile(File1Name); 
        end;
      #61: DoSave;
      #62: DoSearch;
      #64: DoHex;
    end;
  end;
end;

procedure WriteBufferChar(ch: Char);
var CurrentLine: string;
begin
  CurrentLine := GetLine(CursorAbsY);
  while Length(CurrentLine) < CursorAbsX do CurrentLine := CurrentLine + ' ';
  CurrentLine[CursorAbsX] := ch;
  SetLine(CursorAbsY, CurrentLine);
end;

procedure WriteVramChar(ch: Char);
begin
  GotoXY(CursorAbsX, CursorAbsY - ScrollTopY + 2);
  TextColor(White); TextBackground(Blue); Print(ch);
end;

procedure DoBackspace;
var s: string;
begin
  if CursorAbsX > 1 then
  begin
    Dec(CursorAbsX);
    if InsertMode then
    begin
      s := GetLine(CursorAbsY);
      if CursorAbsX <= Length(s) then
      begin
        Delete(s, CursorAbsX, 1);
        SetLine(CursorAbsY, s);
        GotoXY(1, CursorAbsY - ScrollTopY + 2);
        TextColor(White); TextBackground(Blue);
        Print(s);
        if Length(s) < 80 then WriteChars(' ', 80 - Length(s));
      end;
    end
    else
    begin
      WriteBufferChar(' '); WriteVramChar(' ');
    end;
  end
  else if CursorAbsY > 1 then
  begin
    Dec(CursorAbsY); CursorAbsX := 80;
    if CursorAbsY < ScrollTopY then 
    begin 
      Dec(ScrollTopY); RedrawTextViewport; 
    end;
    if not InsertMode then
    begin
      WriteBufferChar(' '); WriteVramChar(' ');
    end;
  end;
end;

procedure DoEnter;
begin
  CursorAbsX := 1;
  if CursorAbsY < MAX_LINES then
  begin
    Inc(CursorAbsY);
    if CursorAbsY >= ScrollTopY + VIEWPORT_HEIGHT then 
    begin 
      Inc(ScrollTopY); RedrawTextViewport; 
    end;
  end;
end;

var
  ch: Char;
  i: Integer;
  s: string;
begin
  for i := 1 to MAX_LINES do TextBuffer[i] := nil;

  CurrentAttr := $1F; CurrentX := 1; CurrentY := 1; ExtendedBuffer := 0;
  InsertMode := True;
  ResetStatus := False;
  InitTextBuffer;
  File1Name := ''; File2Name := '';
  
  if ParamCount >= 1 then File1Name := ParamStr(1);
  DrawUI;
  
  if File1Name <> '' then LoadTextFile(File1Name) else RedrawTextViewport;
  CursorAbsX := 1; CursorAbsY := 1; ScrollTopY := 1;
  
  repeat
    UpdateCursor;
    ch := ReadKey;
    
    if ResetStatus then
    begin
      ResetStatus := False;
      DrawStatusBar;
    end;
    
    if ch = #0 then
    begin
      ch := ReadKey;
      case ch of
        #59: DoNew;
        #60: 
          begin 
            File1Name := GetFilenameGrid(prompt_open1); 
            RedrawTextViewport; 
            if File1Name <> '' then LoadTextFile(File1Name); 
          end;
        #61: DoSave;
        #62: DoSearch;
        #63: DoCompare;
        #64: DoHex;
        #72: 
          if CursorAbsY > 1 then 
          begin 
            Dec(CursorAbsY); 
            if CursorAbsY < ScrollTopY then 
            begin 
              Dec(ScrollTopY); RedrawTextViewport; 
            end; 
          end;
        #80: 
          if CursorAbsY < MAX_LINES then 
          begin 
            Inc(CursorAbsY); 
            if CursorAbsY >= ScrollTopY + VIEWPORT_HEIGHT then 
            begin 
              Inc(ScrollTopY); RedrawTextViewport; 
            end; 
          end;
        #75: 
          if CursorAbsX > 1 then Dec(CursorAbsX) 
          else if CursorAbsY > 1 then 
          begin 
            Dec(CursorAbsY); CursorAbsX := 80; 
            if CursorAbsY < ScrollTopY then 
            begin 
              Dec(ScrollTopY); RedrawTextViewport; 
            end; 
          end;
        #77: 
          if CursorAbsX < 80 then Inc(CursorAbsX) 
          else if CursorAbsY < MAX_LINES then 
          begin 
            Inc(CursorAbsY); CursorAbsX := 1; 
            if CursorAbsY >= ScrollTopY + VIEWPORT_HEIGHT then 
            begin 
              Inc(ScrollTopY); RedrawTextViewport; 
            end; 
          end;
        #73: 
          if CursorAbsY > VIEWPORT_HEIGHT then 
          begin 
            Dec(CursorAbsY, VIEWPORT_HEIGHT); 
            if ScrollTopY > VIEWPORT_HEIGHT then 
              Dec(ScrollTopY, VIEWPORT_HEIGHT) 
            else 
              ScrollTopY := 1; 
            RedrawTextViewport; 
          end 
          else 
          begin 
            CursorAbsY := 1; ScrollTopY := 1; RedrawTextViewport; 
          end;
        #81: 
          if CursorAbsY + VIEWPORT_HEIGHT <= MAX_LINES then 
          begin 
            Inc(CursorAbsY, VIEWPORT_HEIGHT); Inc(ScrollTopY, VIEWPORT_HEIGHT); 
            if ScrollTopY > MAX_LINES - VIEWPORT_HEIGHT + 1 then 
              ScrollTopY := MAX_LINES - VIEWPORT_HEIGHT + 1; 
            RedrawTextViewport; 
          end 
          else 
          begin 
            CursorAbsY := MAX_LINES; 
            ScrollTopY := MAX_LINES - VIEWPORT_HEIGHT + 1; 
            if ScrollTopY < 1 then ScrollTopY := 1; 
            RedrawTextViewport; 
          end;
        #82: { Insert Key toggles mode }
          begin
            InsertMode := not InsertMode;
            CursorOn;
          end;
        #83: { Delete Key }
          begin
            s := GetLine(CursorAbsY);
            if CursorAbsX <= Length(s) then
            begin
              if InsertMode then
                Delete(s, CursorAbsX, 1)
              else
                s[CursorAbsX] := ' ';
              SetLine(CursorAbsY, s);
              
              GotoXY(1, CursorAbsY - ScrollTopY + 2);
              TextColor(White); TextBackground(Blue);
              Print(s);
              if Length(s) < 80 then WriteChars(' ', 80 - Length(s));
            end;
          end;
      end;
    end
    else
    begin
      case ch of
        #27: 
          begin 
            ClrScr; Halt(0); 
          end;
        #8: DoBackspace;
        #13: DoEnter;
        #32..#255: 
        begin
          if InsertMode then
          begin
            s := GetLine(CursorAbsY);
            while Length(s) < CursorAbsX do s := s + ' ';
            if Length(s) >= 80 then s[0] := #79; { Free up space at line end }
            Insert(ch, s, CursorAbsX);
            SetLine(CursorAbsY, s);
            
            GotoXY(1, CursorAbsY - ScrollTopY + 2);
            TextColor(White); TextBackground(Blue);
            Print(s);
            if Length(s) < 80 then WriteChars(' ', 80 - Length(s));
            
            if CursorAbsX < 80 then Inc(CursorAbsX) 
            else if CursorAbsY < MAX_LINES then 
            begin 
              Inc(CursorAbsY); CursorAbsX := 1; 
              if CursorAbsY >= ScrollTopY + VIEWPORT_HEIGHT then 
              begin 
                Inc(ScrollTopY); RedrawTextViewport; 
              end; 
            end;
          end
          else
          begin
            WriteBufferChar(ch); WriteVramChar(ch);
            if CursorAbsX < 80 then Inc(CursorAbsX) 
            else if CursorAbsY < MAX_LINES then 
            begin 
              Inc(CursorAbsY); CursorAbsX := 1; 
              if CursorAbsY >= ScrollTopY + VIEWPORT_HEIGHT then 
              begin 
                Inc(ScrollTopY); RedrawTextViewport; 
              end; 
            end;
          end;
        end;
      end;
    end;
  until false;
end.