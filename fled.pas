program FlabEditor;

{$R-,S-,I-} { Disable runtime bounds checking to prevent false IDE crashes }

uses
  Dos;

const
  MAX_LINES = 12000; { Expanded safely using Dynamic Heap Allocation }
  MAX_DIR_FILES = 512; { Expanded to support large directories }
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
  
  { Typed constant allows safe array-like subscripting }
  hex_digits: string[16] = '0123456789ABCDEF';

type
  TScreenChar = record
    Ch: Char;
    Attr: Byte;
  end;
  TVideoMemory = array[1..25, 1..80] of TScreenChar;
  
  { Dynamic memory structure to bypass 64KB data segment limit }
  PString80 = ^TString80;
  TString80 = string[80];
  TTextBuffer = array[1..MAX_LINES] of PString80;

var
  { Direct absolute pointer mapping to CGA/EGA/VGA Color VRAM text page }
  VRAM: TVideoMemory absolute $B800:0000;

  TextBuffer: TTextBuffer;
  CursorAbsX: Integer; { 1..80 }
  CursorAbsY: Integer; { 1..MAX_LINES }
  ScrollTopY: Integer; { 1..MAX_LINES-1 }
  
  File1Name: string;
  File2Name: string;
  
  FileList: array[1..MAX_DIR_FILES] of string[14];
  FileCount: Integer;
  SelectedFile: Integer;

  { Global color/cursor variables }
  CurrentAttr: Byte;
  CurrentX, CurrentY: Integer;
  ExtendedBuffer: Byte;

{ Forward declarations }
procedure DrawUI; forward;
procedure RedrawTextViewport; forward;
procedure UpdateCursor; forward;
procedure LoadTextFile(FileName: string); forward;

{ Hardware Cursor Control via BIOS Interrupts }
procedure CursorOff; assembler;
asm
  mov ah, 01h
  mov ch, 20h
  mov cl, 00h
  int 10h
end;

procedure CursorOn; assembler;
asm
  mov ah, 01h
  mov ch, 06h
  mov cl, 07h
  int 10h
end;

{ Custom direct VRAM cursor movement }
procedure GotoXY(X, Y: Integer);
begin
  CurrentX := X;
  CurrentY := Y;
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

{ Directly setting colors safely without division }
procedure TextColor(Col: Byte);
begin
  CurrentAttr := Byte((CurrentAttr and $F0) or (Col and $0F));
end;

procedure TextBackground(Col: Byte);
begin
  CurrentAttr := Byte((CurrentAttr and $0F) or ((Col and $07) shl 4));
end;

{ Pure VRAM String Drawer }
procedure Print(s: string);
var
  i: Integer;
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

{ Custom direct VRAM block character writer }
procedure WriteChars(Ch: Char; Count: Integer);
var
  i: Integer;
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
  begin
    GotoXY(1, 25);
  end;
end;

{ Stateful custom Keyboard Listeners using pure BIOS Int 16h calls }
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
var
  Scan, ASCII: Byte;
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

{ Pure VRAM workspace clear }
procedure ClrScr;
var
  r, c: Integer;
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
  if (idx < 1) or (idx > MAX_LINES) or (TextBuffer[idx] = nil) then
    GetLine := ''
  else
    GetLine := TextBuffer[idx]^;
end;

procedure SetLine(idx: Integer; s: string);
begin
  if (idx >= 1) and (idx <= MAX_LINES) then
  begin
    if TextBuffer[idx] = nil then
    begin
      if MaxAvail < SizeOf(TString80) then Exit; { Protect against DOS out-of-memory crashes }
      New(TextBuffer[idx]);
    end;
    TextBuffer[idx]^ := s;
  end;
end;

procedure InitTextBuffer;
var
  i: Integer;
begin
  for i := 1 to MAX_LINES do
  begin
    if TextBuffer[i] <> nil then
    begin
      Dispose(TextBuffer[i]);
      TextBuffer[i] := nil;
    end;
  end;
end;

{ Custom string copy and trimmer }
function TrimTrailingSpaces(s: string): string;
var
  i: Integer;
begin
  i := Length(s);
  while (i > 0) and (s[i] = ' ') do
    Dec(i);
  TrimTrailingSpaces := Copy(s, 1, i);
end;

{ High-performance video background color helper for popups }
procedure DrawDialogFrame;
var
  i, j: Integer;
begin
  TextColor(Black);
  TextBackground(LightGray);
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
var
  MenuBarText: string;
begin
  CurrentAttr := $1F; { White on Blue }
  ClrScr;

  GotoXY(1, 1);
  TextColor(Black);
  TextBackground(LightGray);
  MenuBarText := ' FLED [F1] New [F2] Open [F3] Save [F4] Search [F5] Comp [F6] Hex [ESC] Exit ';
  Print(MenuBarText);
  if Length(MenuBarText) < 80 then
    WriteChars(' ', 80 - Length(MenuBarText));

  RestoreUIColors;
end;

procedure RedrawTextViewport;
var
  i, ScreenY: Integer;
  LineToPrint: string;
begin
  for ScreenY := 1 to VIEWPORT_HEIGHT do
  begin
    GotoXY(1, ScreenY + 1);
    TextColor(White);
    TextBackground(Blue);
    
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
  
  { Render Bottom Info Bar }
  GotoXY(1, 25);
  TextColor(Black);
  TextBackground(LightGray);
  if File1Name = '' then
    Print(' Editing: UNTITLED                                                           ')
  else
  begin
    Print(' Editing: ' + File1Name);
    WriteChars(' ', 80 - 10 - Length(File1Name));
  end;
  RestoreUIColors;
end;

procedure UpdateCursor;
begin
  GotoXY(CursorAbsX, CursorAbsY - ScrollTopY + 2);
end;

procedure LoadDirIntoMemory;
var
  SR: SearchRec;
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
var
  i, Row, Col, DrawCount: Integer;
begin
  TextColor(Black);
  TextBackground(LightGray);
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
var
  ch: Char;
  Done: Boolean;
  TempName, DirName: string;
  FileScrollTop: Integer;
begin
  CursorOff;
  DrawDialogFrame;
  
  TextColor(Black); TextBackground(LightGray);
  GotoXY(10, 7); Print(Prompt);
  GotoXY(10, 11); Print(msg_avail);
  
  LoadDirIntoMemory;
  SelectedFile := 0;
  FileScrollTop := 0;
  Done := false;
  
  repeat
    DrawFileList(FileScrollTop);
    ch := ReadKey;
    if ch = #0 then
    begin
      ch := ReadKey;
      case ch of
        #72: { Up }
          if SelectedFile >= 4 then 
          begin
            Dec(SelectedFile, 4);
            if SelectedFile < FileScrollTop then Dec(FileScrollTop, 4);
          end;
        #80: { Down }
          if SelectedFile + 4 < FileCount then 
          begin
            Inc(SelectedFile, 4);
            if SelectedFile >= FileScrollTop + 24 then Inc(FileScrollTop, 4);
          end;
        #75: { Left }
          if SelectedFile > 0 then 
          begin
            Dec(SelectedFile);
            if SelectedFile < FileScrollTop then Dec(FileScrollTop, 4);
          end;
        #77: { Right }
          if SelectedFile + 1 < FileCount then 
          begin
            Inc(SelectedFile);
            if SelectedFile >= FileScrollTop + 24 then Inc(FileScrollTop, 4);
          end;
        #73: { Page Up }
        begin
          if SelectedFile >= 24 then Dec(SelectedFile, 24) else SelectedFile := 0;
          if FileScrollTop >= 24 then Dec(FileScrollTop, 24) else FileScrollTop := 0;
        end;
        #81: { Page Down }
        begin
          if SelectedFile + 24 < FileCount then Inc(SelectedFile, 24) else SelectedFile := FileCount - 1;
          FileScrollTop := (SelectedFile shr 2) shl 2 - 20; { Keep target safely in viewport }
          if FileScrollTop < 0 then FileScrollTop := 0;
        end;
      end;
    end
    else if ch = #27 then
    begin
      GetFilenameGrid := '';
      Done := true;
    end
    else if ch = #13 then
    begin
      if FileCount > 0 then
      begin
        TempName := FileList[SelectedFile + 1];
        if (Length(TempName) > 2) and (TempName[1] = '[') and (TempName[Length(TempName)] = ']') then
        begin
          { Handle Directory Navigation }
          DirName := Copy(TempName, 2, Length(TempName) - 2);
          {$I-} ChDir(DirName); {$I+}
          if IOResult = 0 then
          begin
            LoadDirIntoMemory;
            SelectedFile := 0;
            FileScrollTop := 0;
          end;
        end
        else
        begin
          GetFilenameGrid := TempName;
          Done := true;
        end;
      end
      else
      begin
        GetFilenameGrid := '';
        Done := true;
      end;
    end;
  until Done;
  RestoreUIColors;
  CursorOn;
end;

function GetFilenameTyping(Prompt: string): string;
var
  InputStr: string;
  ch: Char;
  Done: Boolean;
begin
  DrawDialogFrame;
  TextColor(Black); TextBackground(LightGray);
  GotoXY(10, 7); Print(Prompt);
  GotoXY(10, 9); Print(' > ');
  
  InputStr := '';
  Done := false;
  CursorOn;
  
  repeat
    GotoXY(13 + Length(InputStr), 9);
    ch := ReadKey;
    if ch = #13 then Done := true
    else if ch = #27 then
    begin
      InputStr := '';
      Done := true;
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
      InputStr := InputStr + ch;
      Print(ch);
    end;
  until Done;
  
  CursorOff;
  GetFilenameTyping := InputStr;
  RestoreUIColors;
  CursorOn;
end;

procedure LoadTextFile(FileName: string);
var
  F: Text;
  TempLine: string;
begin
  InitTextBuffer;
  CursorAbsX := 1; CursorAbsY := 1; ScrollTopY := 1;
  
  Assign(F, FileName);
  {$I-} Reset(F); {$I+}
  if IOResult <> 0 then Exit;
  
  while (not EOF(F)) and (CursorAbsY <= MAX_LINES) do
  begin
    if MaxAvail < SizeOf(TString80) then Break; { Prevent out of memory crash on huge files }
    ReadLn(F, TempLine);
    if Length(TempLine) > 80 then TempLine := Copy(TempLine, 1, 80);
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
  CursorAbsX := 1;
  CursorAbsY := 1;
  ScrollTopY := 1;
  RedrawTextViewport;
end;

procedure DoSave;
var
  F: Text;
  i, LastActiveRow: Integer;
begin
  if File1Name = '' then
  begin
    File1Name := GetFilenameTyping(prompt_save);
    RedrawTextViewport;
    if File1Name = '' then Exit;
  end;
  
  Assign(F, File1Name);
  Rewrite(F);
  
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
    for i := 1 to LastActiveRow do
      WriteLn(F, TrimTrailingSpaces(GetLine(i)));
      
  Close(F);
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
  
  SearchRow := 1;
  SearchCol := 1;
  
  repeat
    Found := false;
    while (SearchRow <= MAX_LINES) and (not Found) do
    begin
      ColPos := Pos(SearchStr, Copy(GetLine(SearchRow), SearchCol, 80));
      if ColPos > 0 then
      begin
        Found := true;
        CursorAbsY := SearchRow;
        CursorAbsX := SearchCol + ColPos - 1;
        SearchCol := CursorAbsX + 1; { Advance pointer for next search }
      end
      else
      begin
        Inc(SearchRow);
        SearchCol := 1;
      end;
    end;
    
    if Found then
    begin
      { Adjust viewport to ensure hit is visible }
      if CursorAbsY < ScrollTopY then ScrollTopY := CursorAbsY
      else if CursorAbsY >= ScrollTopY + VIEWPORT_HEIGHT then ScrollTopY := CursorAbsY - VIEWPORT_HEIGHT + 1;
      RedrawTextViewport;
      
      { Visually highlight the found string }
      GotoXY(CursorAbsX, CursorAbsY - ScrollTopY + 2);
      TextColor(Black); TextBackground(LightCyan);
      Print(SearchStr);
      RestoreUIColors;
      
      GotoXY(1, 25);
      TextColor(Black); TextBackground(LightGray);
      Print(' Search Mode: Press ''N'' for next match, ESC to exit... ');
      WriteChars(' ', 80 - 55);
      RestoreUIColors;
      
      repeat
        ch := ReadKey;
        if ch = #0 then ReadKey; { Discard extended }
      until (UpCase(ch) = 'N') or (ch = #27);
      
      if ch = #27 then Break;
    end
    else
    begin
      GotoXY(1, 25);
      TextColor(White); TextBackground(LightRed);
      Print(' ' + msg_not_found + ' Press ESC. ');
      WriteChars(' ', 80 - Length(msg_not_found) - 14);
      RestoreUIColors;
      repeat ch := ReadKey until ch = #27;
      Break;
    end;
  until false;
  RedrawTextViewport;
end;

{ Converts decimal byte to hex without division }
function ByteToHex(b: Byte): string;
var
  s: string[2];
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

{ Robust, Fully Scrollable & Interactive Hex Editor directly bound to unsaved buffer }
procedure DoHex;
var
  F: file;
  FTemp: Text;
  b: Byte;
  Block: array[0..15] of Byte;
  BytesRead: Word;
  Line, i, LastActiveRow: Integer;
  FSize, HexScrollTop: LongInt;
  HexCursorX, HexCursorY, HexNibble: Integer;
  HexPart, AscPart, TempLine: string;
  ch: Char;
  Done: Boolean;
  Val: Byte;
begin
  { Dynamically write current workspace text to a temporary sync file }
  Assign(FTemp, 'FLED$$$.TMP');
  {$I-} Rewrite(FTemp); {$I+}
  if IOResult <> 0 then Exit;
  
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
    for i := 1 to LastActiveRow do
      WriteLn(FTemp, TrimTrailingSpaces(GetLine(i)));
  Close(FTemp);
  
  { Open the temporary binary file to edit directly }
  Assign(F, 'FLED$$$.TMP');
  {$I-} Reset(F, 1); {$I+}
  if IOResult <> 0 then Exit;
  
  FSize := FileSize(F);
  HexScrollTop := 0;
  HexCursorX := 0;
  HexCursorY := 0;
  HexNibble := 0; { 0 = High nibble, 1 = Low nibble }
  Done := false;
  CursorOff;
  
  repeat
    DrawUI;
    GotoXY(1, 2);
    TextColor(Yellow);
    PrintLn('Offset    00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F  ASCII');
    TextColor(White);
    
    Seek(F, HexScrollTop);
    
    for Line := 0 to 21 do
    begin
      if EOF(F) then Break;
      BlockRead(F, Block, 16, BytesRead);
      if BytesRead = 0 then Break;
      
      Print(LongIntToHex(HexScrollTop + (Line * 16)) + '  ');
      
      HexPart := '';
      AscPart := '';
      for i := 0 to 15 do
      begin
        if (i = HexCursorX) and (Line = HexCursorY) then
        begin
          TextColor(Black); TextBackground(LightGray);
        end;
        
        if i < BytesRead then Print(ByteToHex(Block[i]))
        else Print('  ');
        
        TextColor(White); TextBackground(Blue);
        Print(' ');
      end;
      
      Print('| ');
      for i := 0 to 15 do
      begin
        if i < BytesRead then
        begin
          if Block[i] in [32..255] then Print(Char(Block[i])) else Print('.');
        end else Print(' ');
      end;
      PrintLn('');
    end;
    
    GotoXY(1, 25);
    TextColor(Black); TextBackground(LightGray);
    Print(' Hex Edit: Arrows navigate, 0-9/A-F types, PgUp/PgDn scrolls, ESC exits ');
    WriteChars(' ', 80 - 72);
    RestoreUIColors;
    
    { Position physical cursor directly onto the specific nibble of the byte }
    GotoXY(11 + HexCursorX * 3 + HexNibble, HexCursorY + 3);
    CursorOn;
    
    ch := ReadKey;
    CursorOff;
    
    if ch = #0 then
    begin
      ch := ReadKey;
      case ch of
        #72: { Up }
          if HexCursorY > 0 then Dec(HexCursorY)
          else if HexScrollTop >= 16 then Dec(HexScrollTop, 16);
        #80: { Down }
          if HexCursorY < 21 then Inc(HexCursorY)
          else if HexScrollTop + 16 < FSize then Inc(HexScrollTop, 16);
        #75: { Left }
        begin
          if HexNibble = 1 then HexNibble := 0
          else if HexCursorX > 0 then begin Dec(HexCursorX); HexNibble := 1; end
          else if HexCursorY > 0 then begin Dec(HexCursorY); HexCursorX := 15; HexNibble := 1; end
          else if HexScrollTop >= 16 then begin Dec(HexScrollTop, 16); HexCursorX := 15; HexNibble := 1; end;
        end;
        #77: { Right }
        begin
          if HexNibble = 0 then HexNibble := 1
          else if HexCursorX < 15 then begin Inc(HexCursorX); HexNibble := 0; end
          else if HexCursorY < 21 then begin Inc(HexCursorY); HexCursorX := 0; HexNibble := 0; end
          else if HexScrollTop + 16 < FSize then begin Inc(HexScrollTop, 16); HexCursorX := 0; HexNibble := 0; end;
        end;
        #73: { Page Up }
          if HexScrollTop >= 16 * 22 then Dec(HexScrollTop, 16 * 22) else HexScrollTop := 0;
        #81: { Page Down }
          if HexScrollTop + (16 * 22) < FSize then Inc(HexScrollTop, 16 * 22);
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
          
          { Auto advance cursor to next nibble }
          if HexNibble = 0 then HexNibble := 1
          else
          begin
            HexNibble := 0;
            if HexCursorX < 15 then Inc(HexCursorX)
            else if HexCursorY < 21 then begin Inc(HexCursorY); HexCursorX := 0; end
            else if HexScrollTop + 16 < FSize then begin Inc(HexScrollTop, 16); HexCursorX := 0; end;
          end;
        end;
      end;
    end;
  until Done;
  
  Close(F);
  
  { Re-sync changes back into the text buffer seamlessly }
  InitTextBuffer;
  CursorAbsX := 1; CursorAbsY := 1; ScrollTopY := 1;
  
  Assign(FTemp, 'FLED$$$.TMP');
  {$I-} Reset(FTemp); {$I+}
  if IOResult = 0 then
  begin
    while (not EOF(FTemp)) and (CursorAbsY <= MAX_LINES) do
    begin
      if MaxAvail < SizeOf(TString80) then Break;
      ReadLn(FTemp, TempLine);
      if Length(TempLine) > 80 then TempLine := Copy(TempLine, 1, 80);
      SetLine(CursorAbsY, TempLine);
      Inc(CursorAbsY);
    end;
    Close(FTemp);
    Erase(FTemp);
  end;
  
  CursorAbsX := 1; CursorAbsY := 1; ScrollTopY := 1;
  CursorOn;
  RedrawTextViewport;
end;

{ Side-by-Side scrolling Visual Diff Viewer with toggle modes }
procedure DoCompare;
var
  F1, F2: file;
  Buf1, Buf2: array[0..31] of Byte;
  PreBuf1, PreBuf2: array[1..512] of Byte;
  Read1, Read2: Word;
  DiffScrollTop, MaxSize, FSize1, FSize2, CurrOffset: LongInt;
  i, Line, ViewMode, BytesPerLine: Integer;
  ch: Char;
  Done, FilesMatch: Boolean;
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
  
  FSize1 := FileSize(F1);
  FSize2 := FileSize(F2);
  
  { Pre-scan for exact match to save user's time }
  FilesMatch := (FSize1 = FSize2);
  if FilesMatch then
  begin
    while not EOF(F1) do
    begin
      BlockRead(F1, PreBuf1, SizeOf(PreBuf1), Read1);
      BlockRead(F2, PreBuf2, SizeOf(PreBuf2), Read2);
      for i := 1 to Read1 do
      begin
        if PreBuf1[i] <> PreBuf2[i] then
        begin
          FilesMatch := false;
          Break;
        end;
      end;
      if not FilesMatch then Break;
    end;
  end;
  
  if FilesMatch then
  begin
    GotoXY(1, 25);
    TextColor(Black); TextBackground(LightGreen);
    Print(' ' + msg_match + ' Press any key to return... ');
    WriteChars(' ', 80 - Length(msg_match) - 29);
    RestoreUIColors;
    ch := ReadKey;
    if ch = #0 then ReadKey;
    Close(F1); Close(F2);
    RedrawTextViewport;
    Exit;
  end;
  
  Seek(F1, 0);
  Seek(F2, 0);
  if FSize1 > FSize2 then MaxSize := FSize1 else MaxSize := FSize2;
  
  DiffScrollTop := 0;
  ViewMode := 0; { 0 = Combined, 1 = Hex Only, 2 = ASCII Only }
  Done := false;
  CursorOff;
  
  repeat
    if ViewMode = 2 then BytesPerLine := 30 else BytesPerLine := 8;

    DrawUI;
    GotoXY(1, 2);
    TextColor(Yellow);
    
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
        { --- File 1 Hex Data --- }
        TextColor(LightCyan); Print('- ');
        for i := 0 to BytesPerLine - 1 do
        begin
          if i < Read1 then
          begin
            if (i < Read2) and (Buf1[i] <> Buf2[i]) then TextColor(LightRed) else TextColor(LightCyan);
            Print(ByteToHex(Buf1[i]) + ' ');
          end
          else Print('   ');
        end;
        TextColor(White); Print('| ');
        
        { --- File 2 Hex Data --- }
        TextColor(LightGreen); Print('+ ');
        for i := 0 to BytesPerLine - 1 do
        begin
          if i < Read2 then
          begin
            if (i < Read1) and (Buf1[i] <> Buf2[i]) then TextColor(LightRed) else TextColor(LightGreen);
            Print(ByteToHex(Buf2[i]) + ' ');
          end
          else Print('   ');
        end;
        if ViewMode = 0 then
        begin
          TextColor(White); Print('| ');
        end;
      end;
      
      if ViewMode = 0 then
      begin
        { --- Quick ASCII Diff --- }
        for i := 0 to BytesPerLine - 1 do
        begin
          if (i < Read1) and (i < Read2) and (Buf1[i] <> Buf2[i]) then TextColor(LightRed)
          else TextColor(White);
          if (i < Read1) and (Buf1[i] in [32..255]) then Print(Char(Buf1[i]))
          else if (i < Read2) and (Buf2[i] in [32..255]) then Print(Char(Buf2[i]))
          else Print('.');
        end;
      end
      else if ViewMode = 2 then
      begin
        { --- ASCII Only Mode: Side-by-Side Compact --- }
        TextColor(LightCyan); Print('- ');
        for i := 0 to BytesPerLine - 1 do
        begin
          if i < Read1 then
          begin
            if (i < Read2) and (Buf1[i] <> Buf2[i]) then TextColor(LightRed) else TextColor(LightCyan);
            if Buf1[i] in [32..255] then Print(Char(Buf1[i])) else Print('.');
          end else Print(' ');
        end;
        TextColor(White); Print(' | ');
        
        TextColor(LightGreen); Print('+ ');
        for i := 0 to BytesPerLine - 1 do
        begin
          if i < Read2 then
          begin
            if (i < Read1) and (Buf1[i] <> Buf2[i]) then TextColor(LightRed) else TextColor(LightGreen);
            if Buf2[i] in [32..255] then Print(Char(Buf2[i])) else Print('.');
          end else Print(' ');
        end;
      end;
      
      PrintLn('');
    end;
    
    GotoXY(1, 25);
    TextColor(Black); TextBackground(LightGray);
    
    case ViewMode of
      0: ModeName := 'Combined';
      1: ModeName := 'Hex Only';
      2: ModeName := 'ASCII Only';
    end;
    
    InfoStr := ' Diff [' + ModeName + ']: Arrows/PgUp/Dn scroll. [F7] Toggle Mode. [ESC] Exit. ';
    Print(InfoStr);
    WriteChars(' ', 80 - Length(InfoStr));
    RestoreUIColors;
    
    ch := ReadKey;
    if ch = #0 then
    begin
      ch := ReadKey;
      case ch of
        #72: if DiffScrollTop >= BytesPerLine then Dec(DiffScrollTop, BytesPerLine);
        #80: if DiffScrollTop + BytesPerLine < MaxSize then Inc(DiffScrollTop, BytesPerLine);
        #73: if DiffScrollTop >= BytesPerLine * 22 then Dec(DiffScrollTop, BytesPerLine * 22) else DiffScrollTop := 0;
        #81: if DiffScrollTop + (BytesPerLine * 22) < MaxSize then Inc(DiffScrollTop, BytesPerLine * 22);
        #65: if ViewMode = 2 then ViewMode := 0 else Inc(ViewMode); { F7 - Toggle Mode }
      end;
    end
    else if ch = #27 then Done := true;
      
  until Done;
  
  Close(F1); Close(F2);
  CursorOn;
  RedrawTextViewport;
end;

procedure WriteBufferChar(ch: Char);
var
  CurrentLine: string;
begin
  CurrentLine := GetLine(CursorAbsY);
  while Length(CurrentLine) < CursorAbsX do
    CurrentLine := CurrentLine + ' ';
  CurrentLine[CursorAbsX] := ch;
  SetLine(CursorAbsY, CurrentLine);
end;

function ReadBufferChar: Char;
var
  CurrentLine: string;
begin
  CurrentLine := GetLine(CursorAbsY);
  if Length(CurrentLine) < CursorAbsX then
    ReadBufferChar := ' '
  else
    ReadBufferChar := CurrentLine[CursorAbsX];
end;

procedure WriteVramChar(ch: Char);
begin
  GotoXY(CursorAbsX, CursorAbsY - ScrollTopY + 2);
  TextColor(White);
  TextBackground(Blue);
  Print(ch);
end;

procedure DoBackspace;
begin
  if CursorAbsX > 1 then
  begin
    Dec(CursorAbsX);
    WriteBufferChar(' ');
    WriteVramChar(' ');
  end
  else if CursorAbsY > 1 then
  begin
    Dec(CursorAbsY);
    CursorAbsX := 80;
    if CursorAbsY < ScrollTopY then
    begin
      Dec(ScrollTopY);
      RedrawTextViewport;
    end;
    WriteBufferChar(' ');
    WriteVramChar(' ');
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
      Inc(ScrollTopY);
      RedrawTextViewport;
    end;
  end;
end;

var
  ch: Char;
  i: Integer;
begin
  for i := 1 to MAX_LINES do TextBuffer[i] := nil; { Pre-initialize pointers safely }

  CurrentAttr := $1F;
  CurrentX := 1;
  CurrentY := 1;
  ExtendedBuffer := 0;

  InitTextBuffer;
  File1Name := '';
  File2Name := '';
  
  if ParamCount >= 1 then
    File1Name := ParamStr(1);
    
  DrawUI;
  
  if File1Name <> '' then
    LoadTextFile(File1Name)
  else
    RedrawTextViewport;
    
  CursorAbsX := 1;
  CursorAbsY := 1;
  ScrollTopY := 1;
  
  repeat
    UpdateCursor;
    ch := ReadKey;
    
    if ch = #0 then
    begin
      ch := ReadKey;
      case ch of
        #59: DoNew; { F1 New }
        #60: 
        begin
          File1Name := GetFilenameGrid(prompt_open1);
          RedrawTextViewport;
          if File1Name <> '' then
            LoadTextFile(File1Name);
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
              Dec(ScrollTopY);
              RedrawTextViewport;
            end;
          end;
        #80: 
          if CursorAbsY < MAX_LINES then
          begin
            Inc(CursorAbsY);
            if CursorAbsY >= ScrollTopY + VIEWPORT_HEIGHT then
            begin
              Inc(ScrollTopY);
              RedrawTextViewport;
            end;
          end;
        #75: 
          if CursorAbsX > 1 then
            Dec(CursorAbsX)
          else if CursorAbsY > 1 then
          begin
            Dec(CursorAbsY);
            CursorAbsX := 80;
            if CursorAbsY < ScrollTopY then
            begin
              Dec(ScrollTopY);
              RedrawTextViewport;
            end;
          end;
        #77: 
          if CursorAbsX < 80 then
            Inc(CursorAbsX)
          else if CursorAbsY < MAX_LINES then
          begin
            Inc(CursorAbsY);
            CursorAbsX := 1;
            if CursorAbsY >= ScrollTopY + VIEWPORT_HEIGHT then
            begin
              Inc(ScrollTopY);
              RedrawTextViewport;
            end;
          end;
        #73: { Page Up Text Mode }
          if CursorAbsY > VIEWPORT_HEIGHT then
          begin
            Dec(CursorAbsY, VIEWPORT_HEIGHT);
            if ScrollTopY > VIEWPORT_HEIGHT then Dec(ScrollTopY, VIEWPORT_HEIGHT)
            else ScrollTopY := 1;
            RedrawTextViewport;
          end
          else
          begin
            CursorAbsY := 1; ScrollTopY := 1;
            RedrawTextViewport;
          end;
        #81: { Page Down Text Mode }
          if CursorAbsY + VIEWPORT_HEIGHT <= MAX_LINES then
          begin
            Inc(CursorAbsY, VIEWPORT_HEIGHT);
            Inc(ScrollTopY, VIEWPORT_HEIGHT);
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
      end;
    end
    else
    begin
      case ch of
        #27: 
        begin
          ClrScr;
          Halt(0);
        end;
        #8: DoBackspace;
        #13: DoEnter;
        #32..#255: 
        begin
          WriteBufferChar(ch);
          WriteVramChar(ch);
          if CursorAbsX < 80 then
            Inc(CursorAbsX)
          else if CursorAbsY < MAX_LINES then
          begin
            Inc(CursorAbsY);
            CursorAbsX := 1;
            if CursorAbsY >= ScrollTopY + VIEWPORT_HEIGHT then
            begin
              Inc(ScrollTopY);
              RedrawTextViewport;
            end;
          end;
        end;
      end;
    end;
  until false;
end.