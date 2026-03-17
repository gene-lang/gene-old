import terminal
import std/exitprocs

when not defined(windows):
  {.passL: "-lncurses".}

type
  CWindow {.importc: "WINDOW", header: "<curses.h>", incompleteStruct.} = object
  WindowPtr = ptr CWindow

  ViewerColor* = enum
    VcDefault
    VcGene
    VcArray
    VcMap
    VcString
    VcLiteral
    VcOther

  ViewerKey* = enum
    VkNone
    VkTab
    VkBackspace
    VkEscape
    VkUp
    VkDown
    VkPageUp
    VkPageDown
    VkLeft
    VkRight
    VkEnter
    VkF1
    VkF2
    VkF5
    VkF10
    VkResize
    VkQuit
    VkHelp

  ViewerInput* = object
    key*: ViewerKey
    text*: string

const
  NcKeyDown = 258
  NcKeyUp = 259
  NcKeyLeft = 260
  NcKeyRight = 261
  NcKeyPageDown = 338
  NcKeyPageUp = 339
  NcKeyBackspace = 263
  NcKeyEnter = 343
  NcKeyF0 = 264
  NcKeyResize = 410
  NcAttrReverse = 0x0004_0000'u32

proc initscr(): WindowPtr {.importc, header: "<curses.h>".}
proc endwin(): cint {.importc, header: "<curses.h>".}
proc raw_mode(): cint {.importc: "raw", header: "<curses.h>".}
proc noecho(): cint {.importc, header: "<curses.h>".}
proc keypad(win: WindowPtr, enabled: cint): cint {.importc, header: "<curses.h>".}
proc curs_set(visibility: cint): cint {.importc, header: "<curses.h>".}
proc erase(): cint {.importc, header: "<curses.h>".}
proc refresh(): cint {.importc, header: "<curses.h>".}
proc getch(): cint {.importc, header: "<curses.h>".}
proc mvaddnstr(y, x: cint, text: cstring, n: cint): cint {.importc, header: "<curses.h>".}
proc attron(attrs: uint32): cint {.importc, header: "<curses.h>".}
proc attroff(attrs: uint32): cint {.importc, header: "<curses.h>".}
proc has_colors(): bool {.importc, header: "<curses.h>".}
proc start_color(): cint {.importc, header: "<curses.h>".}
proc use_default_colors(): cint {.importc, header: "<curses.h>".}
proc init_pair(pair, fg, bg: cshort): cint {.importc, header: "<curses.h>".}
proc color_set(pair: cshort, opts: pointer): cint {.importc, header: "<curses.h>".}

var stdscr {.importc, header: "<curses.h>".}: WindowPtr
var session_active = false
var hook_installed = false
var quit_proc_installed = false
var colors_enabled = false

const
  NcColorBlue = 4'i16
  NcColorGreen = 2'i16
  NcColorCyan = 6'i16
  NcColorRed = 1'i16
  NcColorMagenta = 5'i16
  NcColorYellow = 3'i16
  NcDefaultBg = -1'i16

  PairGene = 1'i16
  PairArray = 2'i16
  PairMap = 3'i16
  PairString = 4'i16
  PairLiteral = 5'i16
  PairOther = 6'i16

type
  CursesSession* = object
    active*: bool

proc cleanup_terminal() {.noconv.} =
  if not session_active:
    return
  discard endwin()
  session_active = false

proc handle_ctrl_c() {.noconv.} =
  cleanup_terminal()
  quit(130)

proc terminal_height*(): int =
  terminalSize().h

proc terminal_width*(): int =
  terminalSize().w

proc init_colors_if_available() =
  if not has_colors():
    colors_enabled = false
    return
  discard start_color()
  discard use_default_colors()
  discard init_pair(PairGene, NcColorMagenta, NcDefaultBg)
  discard init_pair(PairArray, NcColorCyan, NcDefaultBg)
  discard init_pair(PairMap, NcColorYellow, NcDefaultBg)
  discard init_pair(PairString, NcColorGreen, NcDefaultBg)
  discard init_pair(PairLiteral, NcColorBlue, NcDefaultBg)
  discard init_pair(PairOther, NcColorRed, NcDefaultBg)
  colors_enabled = true

proc color_pair_id(color: ViewerColor): cshort =
  case color
  of VcDefault:
    0
  of VcGene:
    PairGene
  of VcArray:
    PairArray
  of VcMap:
    PairMap
  of VcString:
    PairString
  of VcLiteral:
    PairLiteral
  of VcOther:
    PairOther

proc open_session*(): CursesSession =
  if not quit_proc_installed:
    addExitProc(cleanup_terminal)
    quit_proc_installed = true
  if not hook_installed:
    setControlCHook(handle_ctrl_c)
    hook_installed = true
  discard initscr()
  discard raw_mode()
  discard noecho()
  discard keypad(stdscr, 1)
  discard curs_set(0)
  init_colors_if_available()
  session_active = true
  CursesSession(active: true)

proc close_session*(session: var CursesSession) =
  if not session.active:
    return
  cleanup_terminal()
  when declared(unsetControlCHook):
    if hook_installed:
      unsetControlCHook()
      hook_installed = false
  session.active = false

proc clear_screen*() =
  discard erase()

proc present*() =
  discard refresh()

proc crop_line(text: string, width: int): string =
  if width <= 0:
    return ""
  if text.len <= width:
    return text
  if width <= 3:
    return text[0 ..< width]
  text[0 ..< width - 3] & "..."

proc draw_text*(row, col, width: int, text: string, highlighted = false, color = VcDefault) =
  let line = crop_line(text, width)
  if colors_enabled:
    discard color_set(color_pair_id(color), nil)
  if highlighted:
    discard attron(NcAttrReverse)
  discard mvaddnstr(row.cint, col.cint, line.cstring, line.len.cint)
  if highlighted:
    discard attroff(NcAttrReverse)
  if colors_enabled:
    discard color_set(0, nil)

proc classify_input*(key: int): ViewerInput =
  case key
  of 9:
    ViewerInput(key: VkTab)
  of NcKeyBackspace, 8, 127:
    ViewerInput(key: VkBackspace)
  of 27:
    ViewerInput(key: VkEscape)
  of NcKeyUp:
    ViewerInput(key: VkUp)
  of NcKeyDown:
    ViewerInput(key: VkDown)
  of NcKeyPageUp:
    ViewerInput(key: VkPageUp)
  of NcKeyPageDown:
    ViewerInput(key: VkPageDown)
  of NcKeyLeft:
    ViewerInput(key: VkLeft)
  of NcKeyRight:
    ViewerInput(key: VkRight)
  of NcKeyEnter, 10, 13:
    ViewerInput(key: VkEnter)
  of NcKeyResize:
    ViewerInput(key: VkResize)
  of NcKeyF0 + 1:
    ViewerInput(key: VkF1)
  of NcKeyF0 + 2:
    ViewerInput(key: VkF2)
  of NcKeyF0 + 5:
    ViewerInput(key: VkF5)
  of NcKeyF0 + 10:
    ViewerInput(key: VkF10)
  of 5:
    ViewerInput(key: VkF2)
  of 3:
    ViewerInput(key: VkQuit)
  of int('?'):
    ViewerInput(key: VkHelp)
  else:
    if key >= 32 and key <= 126:
      ViewerInput(key: VkNone, text: $char(key))
    else:
      ViewerInput(key: VkNone)

proc read_input*(): ViewerInput =
  classify_input(getch().int)

proc read_key*(): ViewerKey =
  read_input().key
