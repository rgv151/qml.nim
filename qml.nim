
import strutils, os, streams, coro
import private/bridge, private/capi, private/datatype, private/util

export capi, Q_OBJECT, addType, getType, datatype, util

type
  Common* = ref object of RootObj
    cptr: pointer
    engine: ptr Engine

  Engine* = ref object of Common
    destroyed: bool

  Component* = ref object of Common
  Context* = ref object of Common
  Window* = ref object of Common


var
  initialized: bool
  guiIdleRun: int32
  guiLock: int

  waitingWindows: int

proc run*(f: proc()) =
  if initialized:
    raise newException(SystemError, "qml.run called more than once")
  initialized = true

  newGuiApplication()

  if currentThread() != appThread():
    raise newException(SystemError, "run must be called on the main thread")

  idleTimerInit(addr guiIdleRun)
  coro.start(f)
  coro.run()
  applicationExec()


proc lock*() =
  inc(guiLock)

proc unlock*() =
  if guiLock == 0:
    raise newException(SystemError, "qml.unlock callied without lock being held")
  dec(guiLock)

proc flush*() =
  applicationFlushAll()

#proc changed*() =

type
  ValueFold* = object
    engine*: ptr Engine
    gvalue: proc()
    cvalue: pointer
    init: proc()
    prev: ptr ValueFold
    next : ptr ValueFold
    owner: uint8

proc newEngine*(): Engine =
  result = new(Engine)
  result.cptr = newQEngine()
  result.engine = addr result

proc destroy*(e: var Engine) =
  if not e.destroyed:
    e.destroyed = true
    delObjectLater(e.cptr)

proc load*(e: Engine, location: string, r: Stream): Component =
  let qrc = location.startsWith("qrc:")
  if qrc:
    if not r.isNil:
       return nil
  let
    colon = location.find(':', 0)
    slash = location.find('/', 0)

  var location = location

  if colon == -1 or slash <= colon:
    if location.isAbsolute():
      location = "file:///" & location
    else:
      location = "file:///" & joinPath(getCurrentDir(), location)

  result = new(Component)
  result.cptr = newComponent(to[QQmlEngine](e.cptr), nil)
  if qrc:
    componentLoadURL(to[QQmlComponent](result.cptr), location, location.len.cint)
  else:
    let data = r.readAll()
    componentSetData(to[QQmlComponent](result.cptr), data, data.len.cint, location, location.len.cint)
  let message = componentErrorString(to[QQmlComponent](result.cptr))
  if message != nil:
    # free meesage?
    raise newException(IOError, $message)


proc loadFile*(e: Engine, path: string): Component =
  if path.startsWith("qrc:"):
    return e.load(path, nil)
  var f: File
  if not open(f, path):
    return nil
  defer: close(f)
  return e.load(path, newFileStream(f))

proc loadString*(e: Engine, location: string, qml: string): Component =
  return e.load(location, newStringStream(qml))

proc context*(e: Engine): Context =
  result = new(Context)
  result.engine = e.engine
  result.cptr = engineRootContext(to[QQmlEngine](e.cptr))

proc setVar*(ctx: Context, name: string, value: auto) =
  var
    dv = to[DataValue](alloc(DataValue))
    qname = newString(cstring(name), name.len.cint)
  dataValueOf(dv, value)
  contextSetProperty(to[QQmlContext](ctx.cptr), qname, dv)

proc getVar*(ctx: Context, name: string): ptr DataValue =
  var
    dv: DataValue
    qname = newString(name.cstring, name.len.cint)
  contextGetProperty(to[QQmlContext](ctx.cptr), qname, addr dv)
  result = addr dv

proc spawn(ctx: Context): Context =
  result = new(Context)
  result.engine = ctx.engine
  result.cptr = contextSpawn(to[QQmlContext](ctx.cptr))


proc getPointer*(obj: Common): pointer =
  var
    cptr: ptr GoAddr
    cerr: ptr error
  cerr = objectGoAddr(to[QObject](obj.cptr), addr cptr)
  if not cerr.isNil:
    raise newException(IOError, $(cerr[]))

  result = cptr


proc create*(obj: Common, ctx: Context = nil): Common =
  if objectIsComponent(to[QObject](obj.cptr)) == 0:
    panicf("object is not a component")

  result = new(Common)
  result.engine = obj.engine

  var ctxaddr: ptr QQmlContext
  if ctx != nil:
    ctxaddr = to[QQmlContext](ctx.cptr)

  result.cptr = componentCreate(to[QQmlComponent](obj.cptr), ctxaddr)

proc createWindow*(obj: Common, ctx: Context): Window =
  if objectIsComponent(to[QObject](obj.cptr)) == 0:
    panicf("object is not a component")
  result = new(Window)
  result.engine = obj.engine

  var ctxaddr: ptr QQmlContext
  if ctx != nil:
    ctxaddr = to[QQmlContext](ctx.cptr)
  result.cptr = componentCreateWindow(to[QQmlComponent](obj.cptr), ctxaddr)

proc show*(w: Window) =
  windowShow(to[QQuickWindow](w.cptr))

proc hide*(w: Window) =
  windowHide(to[QQuickWindow](w.cptr))

proc platformId*(w: Window): Common =
  var obj = new(Common)
  obj.engine = w.engine
  obj.cptr = windowRootObject(to[QQuickWindow](w.cptr))

  result = obj

proc wait*(w: Window) =
  inc(waitingWindows)
  windowConnectHidden(to[QQuickWindow](w.cptr))

proc hookWindowHidden*(cptr: ptr QObject) {.exportc.} =
  echo "hookWindowHidden: only quit once no handler is handling this event"
  if waitingWindows <= 0:
    raise newException(SystemError, "no window is waiting")

  dec(waitingWindows)
  if waitingWindows <= 0:
    applicationExit()

var
  types: seq[TypeSpec] = @[]

proc registerType*(location: string, major, minor: int, spec: TypeSpec) =
  var spec = spec

  var typeInfo = getType($spec.name)

  if spec.singleton == 1:
    discard registerSingleton(location.cstring, major.cint, minor.cint, spec.name, addr typeInfo, addr spec)
  else:
    discard capi.registerType(location.cstring, major.cint, minor.cint, spec.name, addr typeInfo, addr spec)

  types.add(spec)

proc registerTypes*(location: string, major, minor: int, types: varargs[TypeSpec]) =
  for t in types:
    registerType(location, major, minor, t)
