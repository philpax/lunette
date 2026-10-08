
-- The shipped configuration sets this once, deliberately, to remember that the
-- demonstration window was already spawned across soft reloads. Written through
-- `_G` so the assignment is visible to the checker.
declare _G: {
    lunetteDemonstrationSpawned: boolean,
    -- Anything else a configuration leaves on the global table.
    [string]: any,
}


declare extern type userdata with end
declare extern type lightuserdata with end


declare extern type Object with
  function release(self)
  function type(self): string
end

export type AudioMaterial =
  | "generic"
  | "brick"
  | "carpet"
  | "ceramic"
  | "concrete"
  | "glass"
  | "gravel"
  | "metal"
  | "plaster"
  | "rock"
  | "wood"

export type AudioShareMode =
  | "shared"
  | "exclusive"

export type AudioType =
  | "playback"
  | "capture"

export type Effect =
  | "absorption"
  | "attenuation"
  | "occlusion"
  | "reverb"
  | "spatialization"
  | "transmission"

export type ReverbMode =
  | "listener"
  | "source"

export type ReverbType =
  | "convolution"
  | "parametric"

export type TimeUnit =
  | "seconds"
  | "frames"

export type VolumeUnit =
  | "linear"
  | "db"

declare extern type AudioMesh extends Object with
  function clone(self): AudioMesh
  function getOrientation(self): (number, number, number, number)
  function getPose(self): (number, number, number, number, number, number, number)
  function getPosition(self): (number, number, number)
  function getScale(self): (number, number, number)
  function getTransform(self): (number, number, number, number, number, number, number, number, number, number)
  function isEnabled(self): boolean
  function setEnabled(self, enabled: boolean)
  function setOrientation(self, angle: number, ax: number, ay: number, az: number)
  function setOrientation(self, orientation: quaternion)
  function setPose(self, x: number, y: number, z: number, angle: number, ax: number, ay: number, az: number)
  function setPose(self, position: vector, orientation: quaternion)
  function setPosition(self, x: number, y: number, z: number)
  function setPosition(self, position: vector)
  function setScale(self, sx: number, sy: number, sz: number)
  function setScale(self, scale: vector)
  function setTransform(self, x: number, y: number, z: number, sx: number, sy: number, sz: number, angle: number, ax: number, ay: number, az: number)
  function setTransform(self, position: vector, scale: vector, orientation: quaternion)
  function setTransform(self, transform: Mat4)
end

declare extern type Source extends Object with
  function clone(self): Source
  function getAbsorption(self): (number, number, number)
  function getCone(self): (number, number, number)
  function getDuration(self, unit: TimeUnit?): number
  function getFalloff(self): (number, number)
  function getOcclusion(self): (number, number)
  function getOrientation(self): (number, number, number, number)
  function getPitch(self): number
  function getPose(self): (number, number, number, number, number, number, number)
  function getPosition(self): (number, number, number)
  function getRadius(self): number
  function getReverb(self): (number, ReverbMode)
  function getSound(self): Sound
  function getSpatialization(self): number
  function getVolume(self, units: VolumeUnit?): number
  function isLooping(self): boolean
  function isPlaying(self): boolean
  function isSpatial(self): boolean
  function pause(self)
  function play(self): boolean
  function seek(self, position: number, unit: TimeUnit?)
  function setAbsorption(self, low: number, mid: number, high: number)
  function setAbsorption(self, enable: boolean?)
  function setCone(self, innerAngle: number, outerAngle: number, outerVolume: number)
  function setCone(self, enable: boolean?)
  function setFalloff(self, minDistance: number, minVolume: number)
  function setFalloff(self, enable: boolean?)
  function setLooping(self, loop: boolean)
  function setOcclusion(self, rays: number, transmissionRays: number)
  function setOcclusion(self, enable: boolean?)
  function setOrientation(self, angle: number, ax: number, ay: number, az: number)
  function setOrientation(self, orientation: quaternion)
  function setPitch(self, pitch: number)
  function setPose(self, x: number, y: number, z: number, angle: number, ax: number, ay: number, az: number)
  function setPose(self, position: vector, orientation: quaternion)
  function setPosition(self, x: number, y: number, z: number)
  function setPosition(self, position: vector)
  function setRadius(self, radius: number)
  function setReverb(self, level: number, mode: ReverbMode)
  function setReverb(self, enable: boolean?)
  function setSpatialization(self, spatialization: number)
  function setSpatialization(self, enable: boolean?)
  function setVolume(self, volume: number, units: VolumeUnit?)
  function stop(self)
  function tell(self, unit: TimeUnit?): number
end

export type AudioModule = {
  getDevice: (type: AudioType?) -> (string?, userdata?),
  getDevices: (type: AudioType?) -> {{ read id: userdata, read name: string, read default: boolean }},
  getOrientation: () -> (number, number, number, number),
  getPose: () -> (number, number, number, number, number, number, number),
  getPosition: () -> (number, number, number),
  getSampleRate: () -> number,
  getStream: () -> AudioStream?,
  getVolume: (units: VolumeUnit?) -> number,
  isStarted: (type: AudioType?) -> boolean,
  newAudioMesh:
    & ((vertices: {}, indices: {}, material: AudioMaterial | { read [number]: AudioMaterial } | nil | nil) -> AudioMesh)
    & ((modelData: ModelData, material: AudioMaterial | { read [number]: AudioMaterial } | nil | nil) -> AudioMesh)
    & ((mesh: Mesh, material: AudioMaterial | { read [number]: AudioMaterial } | nil | nil) -> AudioMesh),
  newSource:
    & ((file: string | Blob, options: { read decode: boolean?, read spatial: boolean?, read pitchable: boolean? }?) -> Source)
    & ((sound: Sound, options: { read decode: boolean?, read spatial: boolean?, read pitchable: boolean? }?) -> Source)
    & ((stream: Sound, options: { read decode: boolean?, read spatial: boolean?, read pitchable: boolean? }?) -> Source),
  setDevice: (type: AudioType?, id: userdata?, stream: AudioStream | boolean | nil, mode: AudioShareMode?) -> boolean,
  setHRTF:
    & ((file: string | Blob) -> ())
    & (() -> ()),
  setOrientation:
    & ((angle: number, ax: number, ay: number, az: number) -> ())
    & ((orientation: quaternion) -> ()),
  setPose:
    & ((x: number, y: number, z: number, angle: number, ax: number, ay: number, az: number) -> ())
    & ((position: vector, orientation: quaternion) -> ()),
  setPosition:
    & ((x: number, y: number, z: number) -> ())
    & ((position: vector) -> ()),
  setVolume: (volume: number, units: VolumeUnit?) -> (),
  start: (type: AudioType?) -> (boolean, string?),
  stop: (type: AudioType?) -> (boolean, string?),
  update: (dt: number) -> (),
}

export type AnimationProperty =
  | "translation"
  | "rotation"
  | "scale"
  | "weights"

export type AttributeType =
  | "i8"
  | "u8"
  | "i16"
  | "u16"
  | "i32"
  | "u32"
  | "f32"

export type ChannelLayout =
  | "mono"
  | "stereo"
  | "ambisonic"

export type DefaultAttribute =
  | "position"
  | "normal"
  | "uv"
  | "color"
  | "tangent"
  | "joints"
  | "weights"

export type ModelDrawMode =
  | "points"
  | "lines"
  | "linestrip"
  | "lineloop"
  | "strip"
  | "triangles"
  | "fan"

export type SampleFormat =
  | "f32"
  | "i16"

export type SmoothMode =
  | "step"
  | "linear"
  | "cubic"

export type TextureFormat =
  | "r8"
  | "rg8"
  | "rgba8"
  | "bgra8"
  | "r16"
  | "rg16"
  | "rgba16"
  | "r16f"
  | "rg16f"
  | "rgba16f"
  | "r32f"
  | "rg32f"
  | "rgba32f"
  | "rgb565"
  | "rgb5a1"
  | "rgb10a2"
  | "rg11b10f"
  | "d16"
  | "d24"
  | "d24s8"
  | "d32f"
  | "d32fs8"
  | "bc1"
  | "bc2"
  | "bc3"
  | "bc4u"
  | "bc4s"
  | "bc5u"
  | "bc5s"
  | "bc6uf"
  | "bc6sf"
  | "bc7"
  | "astc4x4"
  | "astc5x4"
  | "astc5x5"
  | "astc6x5"
  | "astc6x6"
  | "astc8x5"
  | "astc8x6"
  | "astc8x8"
  | "astc10x5"
  | "astc10x6"
  | "astc10x8"
  | "astc10x10"
  | "astc12x10"
  | "astc12x12"

declare extern type AudioStream extends Object with
  function getCapacity(self): number
  function getChannelCount(self): number
  function getChannelLayout(self): ChannelLayout
  function getFormat(self): SampleFormat
  function getReadCapacity(self): number
  function getSampleRate(self): number
  function getWriteCapacity(self): number
  function read(self, count: number?): {number}
  function read(self, count: number?, sound: Sound, offset: number?): number
  function read(self, count: number?, blob: Blob, offset: number?): number
  function write(self, table: { read [number]: number }): number
  function write(self, sound: Sound): number
  function write(self, blob: Blob): number
end

declare extern type Blob extends Object with
  function getF32(self, offset: number?, count: number?): ...number
  function getF64(self, offset: number?, count: number?): ...number
  function getI16(self, offset: number?, count: number?): ...number
  function getI32(self, offset: number?, count: number?): ...number
  function getI8(self, offset: number?, count: number?): ...number
  function getName(self): string
  function getPointer(self): userdata
  function getSize(self): number
  function getString(self, offset: number?, size: number?): string
  function getU16(self, offset: number?, count: number?): ...number
  function getU32(self, offset: number?, count: number?): ...number
  function getU8(self, offset: number?, count: number?): ...number
  function setF32(self, offset: number, ...: number)
  function setF32(self, offset: number, table: { read [number]: number })
  function setF64(self, offset: number, ...: number)
  function setF64(self, offset: number, table: { read [number]: number })
  function setI16(self, offset: number, ...: number)
  function setI16(self, offset: number, table: { read [number]: number })
  function setI32(self, offset: number, ...: number)
  function setI32(self, offset: number, table: { read [number]: number })
  function setI8(self, offset: number, ...: number)
  function setI8(self, offset: number, table: { read [number]: number })
  function setU16(self, offset: number, ...: number)
  function setU16(self, offset: number, table: { read [number]: number })
  function setU32(self, offset: number, ...: number)
  function setU32(self, offset: number, table: { read [number]: number })
  function setU8(self, offset: number, ...: number)
  function setU8(self, offset: number, table: { read [number]: number })
end

declare extern type Image extends Object with
  function encode(self): Blob
  function getBlob(self): Blob
  function getDimensions(self): (number, number)
  function getFormat(self): TextureFormat
  function getHeight(self): number
  function getPixel(self, x: number, y: number): (number, number, number, number)
  function getPointer(self, level: number?, layer: number?): userdata
  function getWidth(self): number
  function mapPixel(self, callback: () -> (), x: number?, y: number?, w: number?, h: number?)
  function paste(self, source: Image, x: number?, y: number?, fromX: number?, fromY: number?, width: number?, height: number?)
  function setPixel(self, x: number, y: number, r: number, g: number, b: number, a: number?)
end

declare extern type ModelData extends Object with
  function getAnimationChannelCount(self, animation: number | string): number
  function getAnimationCount(self): number
  function getAnimationDuration(self, animation: string | number): number
  function getAnimationKeyframe(self, animation: number, channel: number, keyframe: number): (number, ...number)
  function getAnimationKeyframeCount(self, animation: string | number, channel: number): number
  function getAnimationName(self, index: number): string | nil
  function getAnimationNode(self, animation: number, channel: number): number
  function getAnimationProperty(self, animation: string | number, channel: number): AnimationProperty
  function getAnimationSmoothMode(self, animation: string | number, channel: number): SmoothMode
  function getBlendShapeCount(self): number
  function getBlendShapeName(self, index: number): string
  function getBoundingBox(self): (number, number, number, number, number, number)
  function getBoundingBox(self, mesh: number): (number, number, number, number, number, number)
  function getBoundingBox(self, mesh: number, part: number): (number, number, number, number, number, number)
  function getCenter(self): (number, number, number)
  function getCenter(self, mesh: number): (number, number, number)
  function getCenter(self, mesh: number, part: number): (number, number, number)
  function getDepth(self): number
  function getDepth(self, mesh: number): number
  function getDepth(self, mesh: number, part: number): number
  function getDimensions(self): (number, number, number)
  function getDimensions(self, mesh: number): (number, number, number)
  function getDimensions(self, mesh: number, part: number): (number, number, number)
  function getHeight(self): number
  function getHeight(self, mesh: number): number
  function getHeight(self, mesh: number, part: number): number
  function getImage(self, index: number): Image
  function getImageCount(self): number
  function getMaterial(self, material: string | number): { read color: {number}, read glow: {number}, read uvShift: {number}, read uvScale: {number}, read metalness: number, read roughness: number, read clearcoat: number, read clearcoatRoughness: number, read occlusionStrength: number, read normalScale: number, read alphaCutoff: number, read texture: number | nil, read glowTexture: number | nil, read occlusionTexture: number | nil, read metalnessTexture: number | nil, read roughnessTexture: number | nil, read clearcoatTexture: number | nil, read normalTexture: number | nil }
  function getMaterialCount(self): number
  function getMaterialName(self, index: number): string
  function getMeshBlendShapeCount(self, mesh: number): number
  function getMeshBlendShapeName(self, mesh: number, blendshape: number): string
  function getMeshBlendVertex(self, mesh: number, blendshape: number, vertex: number): (number, number, number, number, number, number, number, number, number)
  function getMeshCount(self): number
  function getMeshDrawMode(self, mesh: number): ModelDrawMode
  function getMeshDrawRange(self, mesh: number, part: number?): (number, number)
  function getMeshIndex(self, mesh: number, index: number): number
  function getMeshIndexCount(self, mesh: number): number
  function getMeshMaterial(self, mesh: number, part: number?): number | nil
  function getMeshPartCount(self, mesh: number): number
  function getMeshVertex(self, mesh: number, vertex: number): (number, number, number, number, number, number, number, number, number, number, number, number, number, number, number, number, number)
  function getMeshVertexCount(self, mesh: number): number
  function getMetadata(self): string
  function getNodeChild(self, node: string | number): number | nil
  function getNodeChildren(self, node: string | number): {number}
  function getNodeCount(self): number
  function getNodeMesh(self, node: string | number): number | nil
  function getNodeName(self, index: number): string
  function getNodeOrientation(self, node: string | number): (number, number, number, number)
  function getNodeParent(self, node: string | number): number
  function getNodePose(self, node: string | number): (number, number, number, number, number, number, number)
  function getNodePosition(self, node: string | number): (number, number, number)
  function getNodeScale(self, node: string | number): (number, number, number)
  function getNodeSibling(self, node: string | number): number | nil
  function getNodeSkin(self, node: string | number): number
  function getNodeTransform(self, node: string | number): (number, number, number, number, number, number, number, number, number, number)
  function getRootNode(self): number
  function getSkinCount(self): number
  function getSkinInverseBindMatrix(self, skin: number, joint: number): ...number
  function getSkinJoints(self, skin: number): {}
  function getWidth(self): number
  function getWidth(self, mesh: number): number
  function getWidth(self, mesh: number, part: number): number
end

declare extern type Rasterizer extends Object with
  function getAdvance(self, glyph: string | number): number
  function getAscent(self): number
  function getBearing(self, glyph: string | number): number
  function getBoundingBox(self, glyph: string | number): (number, number, number, number)
  function getBoundingBox(self): (number, number, number, number)
  function getCurves(self, glyph: string | number, three: boolean): {}
  function getDescent(self): number
  function getDimensions(self, glyph: string): (number, number)
  function getDimensions(self): (number, number)
  function getFontSize(self): number
  function getGlyphCount(self): number
  function getHeight(self, glyph: string | number): number
  function getHeight(self): number
  function getKerning(self, first: string | number, second: string | number): number
  function getLeading(self): number
  function getWidth(self, glyph: string | number): number
  function getWidth(self): number
  function hasGlyphs(self, ...: string | number): boolean
  function newImage(self, glyph: string | number, spread: number?, padding: number?): Image
end

declare extern type Sound extends Object with
  function getBlob(self): Blob
  function getByteStride(self): number
  function getChannelCount(self): number
  function getChannelLayout(self): ChannelLayout
  function getDuration(self): number
  function getFormat(self): SampleFormat
  function getFrame(self, offset: number): ...number
  function getFrameCount(self): number
  function getFrames(self, count: number?, srcOffset: number?): ({number}, number)
  function getFrames(self, t: {}, count: number?, srcOffset: number?, dstOffset: number?): ({number}, number)
  function getFrames(self, blob: Blob, count: number?, srcOffset: number?, dstOffset: number?): number
  function getFrames(self, sound: Sound, count: number?, srcOffset: number?, dstOffset: number?): number
  function getSampleCount(self): number
  function getSampleRate(self): number
  function isCompressed(self): boolean
  function setFrame(self, offset: number, ...: number)
  function setFrames(self, source: {} | Blob | Sound, count: number?, dstOffset: number?, srcOffset: number?): number
end

export type DataModule = {
  newAudioStream: (capacity: number, format: SampleFormat?, channels: number, rate: number?) -> AudioStream,
  newBlob:
    & ((size: number, name: string?) -> Blob)
    & ((contents: string, name: string?) -> Blob)
    & ((source: Blob, name: string?) -> Blob),
  newBlobView: (parent: Blob, offset: number, extent: number?, name: string?) -> Blob,
  newImage:
    & ((file: string | Blob) -> Image)
    & ((width: number, height: number, format: TextureFormat?, data: Blob?) -> Image)
    & ((source: Image) -> Image),
  newModelData: (file: string | Blob) -> ModelData,
  newRasterizer:
    & ((file: string | Blob, size: number?) -> Rasterizer)
    & ((file: string | Blob, atlas: Image?) -> Rasterizer)
    & ((size: number?) -> Rasterizer),
  newSound:
    & ((frames: number, format: SampleFormat?, channels: number?, sampleRate: number?, contents: Blob?) -> Sound)
    & ((file: string | Blob, decode: boolean?) -> Sound),
}

export type DisplayType =
  | "headset"
  | "window"

export type KeyCode =
  | "a"
  | "b"
  | "c"
  | "d"
  | "e"
  | "f"
  | "g"
  | "h"
  | "i"
  | "j"
  | "k"
  | "l"
  | "m"
  | "n"
  | "o"
  | "p"
  | "q"
  | "r"
  | "s"
  | "t"
  | "u"
  | "v"
  | "w"
  | "x"
  | "y"
  | "z"
  | "0"
  | "1"
  | "2"
  | "3"
  | "4"
  | "5"
  | "6"
  | "7"
  | "8"
  | "9"
  | "space"
  | "return"
  | "tab"
  | "escape"
  | "backspace"
  | "up"
  | "down"
  | "left"
  | "right"
  | "home"
  | "end"
  | "pageup"
  | "pagedown"
  | "insert"
  | "delete"
  | "f1"
  | "f2"
  | "f3"
  | "f4"
  | "f5"
  | "f6"
  | "f7"
  | "f8"
  | "f9"
  | "f10"
  | "f11"
  | "f12"
  | "`"
  | "-"
  | "="
  | "["
  | "]"
  | "\\"
  | ";"
  | "'"
  | ","
  | "."
  | "/"
  | "kp0"
  | "kp1"
  | "kp2"
  | "kp3"
  | "kp4"
  | "kp5"
  | "kp6"
  | "kp7"
  | "kp8"
  | "kp9"
  | "kp."
  | "kp/"
  | "kp*"
  | "kp-"
  | "kp+"
  | "kpenter"
  | "kp="
  | "lctrl"
  | "lshift"
  | "lalt"
  | "lgui"
  | "rctrl"
  | "rshift"
  | "ralt"
  | "rgui"
  | "capslock"
  | "scrolllock"
  | "numlock"

export type EventModule = {
  clear: () -> (),
  poll: () -> (() -> ()),
  push: (name: string, ...any) -> (),
  quit: (code: number?) -> (),
  restart: () -> (),
}

export type FileAction =
  | "create"
  | "delete"
  | "modify"
  | "rename"

export type OpenMode =
  | "r"
  | "w"
  | "a"

declare extern type File extends Object with
  function getMode(self): OpenMode
  function getPath(self): string
  function getSize(self): (number?, string?)
  function isEOF(self): boolean
  function read(self, bytes: number): (string?, number | string)
  function seek(self, offset: number)
  function tell(self): number
  function write(self, string: string, size: number?): (boolean, string?)
  function write(self, blob: Blob, size: number?): (boolean, string?)
end

export type FilesystemModule = {
  append: (filename: string, content: string | Blob) -> (boolean, string?),
  createDirectory: (path: string) -> (boolean, string?),
  getAppdataDirectory: () -> string?,
  getDirectoryItems: (path: string) -> {string},
  getExecutablePath: () -> string?,
  getIdentity: () -> string?,
  getLastModified: (path: string) -> (number?, string?),
  getRealDirectory: (path: string) -> string?,
  getRequirePath: () -> string,
  getSaveDirectory: () -> string,
  getSize: (file: string) -> (number?, string?),
  getSource: () -> string?,
  getUserDirectory: () -> string?,
  getWorkingDirectory: () -> string?,
  isDirectory: (path: string) -> boolean,
  isFile: (path: string) -> boolean,
  isFused: () -> boolean,
  load: (filename: string, mode: string?) -> (() -> ()),
  mount: (path: string, mountpoint: string?, append: boolean?, root: string?) -> (boolean, string?),
  newBlob: (filename: string) -> Blob,
  newFile: (path: string, mode: OpenMode) -> (File?, string?),
  read: (filename: string) -> (string?, string?),
  remove: (path: string) -> (boolean, string?),
  setIdentity: (identity: string) -> (),
  setRequirePath: (path: string?) -> (),
  unmount: (path: string) -> boolean,
  unwatch: () -> (),
  watch: () -> (),
  write: (filename: string, content: string | Blob) -> (boolean, string?),
}

export type BlendAlphaMode =
  | "alphamultiply"
  | "premultiplied"

export type BlendFactor =
  | "zero"
  | "one"
  | "srccolor"
  | "oneminussrccolor"
  | "srcalpha"
  | "oneminussrcalpha"
  | "dstcolor"
  | "oneminusdstcolor"
  | "dstalpha"
  | "oneminusdstalpha"
  | "srcalphasaturated"

export type BlendMode =
  | "alpha"
  | "add"
  | "subtract"
  | "multiply"
  | "lighten"
  | "darken"
  | "screen"
  | "none"

export type BlendOp =
  | "add"
  | "subtract"
  | "reversesubtract"
  | "min"
  | "max"

export type CompareMode =
  | "none"
  | "equal"
  | "notequal"
  | "less"
  | "lequal"
  | "greater"
  | "gequal"

export type CullMode =
  | "none"
  | "back"
  | "front"

export type DataLayout =
  | "packed"
  | "std140"
  | "std430"

export type DataType =
  | "i8x4"
  | "u8x4"
  | "sn8x4"
  | "un8x4"
  | "sn10x3"
  | "un10x3"
  | "i16"
  | "i16x2"
  | "i16x4"
  | "u16"
  | "u16x2"
  | "u16x4"
  | "sn16x2"
  | "sn16x4"
  | "un16x2"
  | "un16x4"
  | "i32"
  | "i32x2"
  | "i32x3"
  | "i32x4"
  | "u32"
  | "u32x2"
  | "u32x3"
  | "u32x4"
  | "f16x2"
  | "f16x4"
  | "f32"
  | "f32x2"
  | "f32x3"
  | "f32x4"
  | "mat2"
  | "mat3"
  | "mat4"
  | "index16"
  | "index32"

export type DefaultShader =
  | "unlit"
  | "normal"
  | "font"
  | "cubemap"
  | "equirect"
  | "fill"

export type DrawMode =
  | "points"
  | "lines"
  | "triangles"

export type DrawStyle =
  | "fill"
  | "line"

export type FilterMode =
  | "nearest"
  | "linear"
  | "cubic"

export type HorizontalAlign =
  | "left"
  | "center"
  | "right"

export type MeshStorage =
  | "cpu"
  | "gpu"

export type OriginType =
  | "root"
  | "parent"

export type ProjectionType =
  | "orthographic"
  | "perspective"
  | "asymmetric"
  | "matrix"

export type ShaderFlag =
  | "pointSize"
  | "passColor"
  | "materialColor"
  | "vertexColors"
  | "uvTransform"
  | "alphaCutoff"
  | "glow"
  | "normalMap"
  | "vertexTangents"
  | "colorTexture"
  | "glowTexture"
  | "metalnessTexture"
  | "roughnessTexture"
  | "ambientOcclusion"
  | "clearcoatTexture"
  | "tonemap"

export type ShaderStage =
  | "vertex"
  | "fragment"
  | "compute"

export type ShaderType =
  | "graphics"
  | "compute"

export type StackType =
  | "transform"
  | "state"

export type StencilAction =
  | "keep"
  | "zero"
  | "replace"
  | "increment"
  | "decrement"
  | "incrementwrap"
  | "decrementwrap"
  | "invert"

export type TextureFeature =
  | "sample"
  | "render"
  | "storage"
  | "blit"
  | "cubic"

export type TextureType =
  | "2d"
  | "3d"
  | "cube"
  | "array"

export type TextureUsage =
  | "sample"
  | "render"
  | "storage"
  | "transfer"

export type VerticalAlign =
  | "top"
  | "middle"
  | "bottom"

export type Winding =
  | "clockwise"
  | "counterclockwise"

export type WrapMode =
  | "clamp"
  | "repeat"
  | "mirror"
  | "border"

declare extern type Buffer extends Object with
  function clear(self, offset: number?, extent: number?, value: number?)
  function getData(self, index: number?, count: number?): {}
  function getFormat(self): {{ read name: string, read type: any, read offset: number, read length: number, read stride: number }}
  function getLength(self): number
  function getSize(self): number
  function getStride(self): number
  function newBlob(self, offset: number?, extent: number?): Blob
  function newReadback(self, offset: number?, extent: number?): Readback
  function setData(self, table: {}, destinationIndex: number?, sourceIndex: number?, count: number?)
  function setData(self, ...: number)
  function setData(self, vector: any)
  function setData(self, blob: Blob, destinationOffset: number?, sourceOffset: number?, size: number?)
  function setData(self, buffer: Buffer, destinationOffset: number?, sourceOffset: number?, size: number?)
end

declare extern type Font extends Object with
  function getAscent(self): number
  function getDescent(self): number
  function getHeight(self): number
  function getKerning(self, first: string | number, second: string | number): number
  function getLineSpacing(self): number
  function getLines(self, string: string, wrap: number): {string}
  function getLines(self, strings: { read [number]: any }, wrap: number): {string}
  function getPixelDensity(self): number
  function getRasterizer(self): Rasterizer
  function getVertices(self, string: string, wrap: number?, halign: HorizontalAlign, valign: VerticalAlign): ({number}, Material)
  function getVertices(self, strings: { read [number]: any }, wrap: number?, halign: HorizontalAlign, valign: VerticalAlign): ({number}, Material)
  function getWidth(self, string: string): number
  function getWidth(self, strings: { read [number]: any }): number
  function setLineSpacing(self, spacing: number)
  function setPixelDensity(self, density: number)
  function setPixelDensity(self)
end

declare extern type Material extends Object with
  function getProperties(self): {}
end

declare extern type Mesh extends Object with
  function buildRaytracer(self)
  function computeBoundingBox(self): boolean
  function getBaseVertex(self): number
  function getBoundingBox(self): (number, number, number, number, number, number)
  function getDrawMode(self): DrawMode
  function getDrawRange(self): (number, number, number)
  function getDrawRange(self)
  function getIndexBuffer(self): Buffer
  function getIndices(self): {number}
  function getMaterial(self): Material
  function getVertexBuffer(self): Buffer
  function getVertexCount(self): number
  function getVertexFormat(self): {{string | DataType | number}}
  function getVertexStride(self): number
  function getVertices(self, index: number?, count: number?): {{number}}
  function setBaseVertex(self, offset: number?)
  function setBoundingBox(self, minx: number, maxx: number, miny: number, maxy: number, minz: number, maxz: number)
  function setBoundingBox(self)
  function setDrawMode(self, mode: DrawMode)
  function setDrawRange(self, start: number, count: number)
  function setDrawRange(self, start: number, count: number, offset: number)
  function setDrawRange(self)
  function setIndexBuffer(self, buffer: Buffer)
  function setIndices(self, t: { read [number]: number })
  function setIndices(self, blob: Blob, type: DataType)
  function setIndices(self)
  function setMaterial(self, material: Material)
  function setMaterial(self, texture: Texture)
  function setVertices(self, vertices: { read [number]: { read [number]: number } }, index: number?, count: number?)
  function setVertices(self, blob: Blob, index: number?, count: number?)
end

declare extern type Model extends Object with
  function animate(self, animation: string, time: number, blend: number?)
  function buildRaytracer(self)
  function clone(self): Model
  function getAnimationCount(self): number
  function getAnimationDuration(self, animation: string | number): number
  function getAnimationName(self, index: number): string | nil
  function getBlendShapeCount(self): number
  function getBlendShapeName(self, index: number): string
  function getBlendShapeWeight(self, blendshape: string | number): number
  function getBoundingBox(self): (number, number, number, number, number, number)
  function getBoundingBox(self, mesh: number): (number, number, number, number, number, number)
  function getBoundingBox(self, mesh: number, part: number): (number, number, number, number, number, number)
  function getCenter(self): (number, number, number)
  function getCenter(self, mesh: number): (number, number, number)
  function getCenter(self, mesh: number, part: number): (number, number, number)
  function getDepth(self): number
  function getDepth(self, mesh: number): number
  function getDepth(self, mesh: number, part: number): number
  function getDimensions(self): (number, number, number)
  function getDimensions(self, mesh: number): (number, number, number)
  function getDimensions(self, mesh: number, part: number): (number, number, number)
  function getHeight(self): number
  function getHeight(self, mesh: number): number
  function getHeight(self, mesh: number, part: number): number
  function getIndexBuffer(self): Buffer
  function getMaterial(self, which: string | number): Material
  function getMaterialCount(self): number
  function getMaterialName(self, index: number): string
  function getMesh(self, index: number): Mesh
  function getMeshBlendShapeCount(self, mesh: number): number
  function getMeshBlendShapeName(self, mesh: number, blendshape: number): string
  function getMeshCount(self): number
  function getMeshDrawMode(self, mesh: number): ModelDrawMode
  function getMeshDrawRange(self, mesh: number, part: number?): (number, number)
  function getMeshIndexCount(self, mesh: number): number
  function getMeshMaterial(self, mesh: number, part: number?): number | nil
  function getMeshPartCount(self, mesh: number): number
  function getMeshVertexCount(self, mesh: number): number
  function getMetadata(self): string
  function getNodeChild(self, node: string | number): number | nil
  function getNodeChildren(self, node: string | number): {number}
  function getNodeCount(self): number
  function getNodeMesh(self, node: string | number): number | nil
  function getNodeName(self, index: number): string
  function getNodeOrientation(self, node: string | number, origin: OriginType?): (number, number, number, number)
  function getNodeParent(self, node: string | number): number
  function getNodePose(self, node: string | number, origin: OriginType?): (number, number, number, number, number, number, number)
  function getNodePosition(self, node: string | number, space: OriginType?): (number, number, number)
  function getNodeScale(self, node: string | number, origin: OriginType?): (number, number, number)
  function getNodeSibling(self, node: string | number): number | nil
  function getNodeTransform(self, node: string | number, origin: OriginType?): (number, number, number, number, number, number, number, number, number, number)
  function getRootNode(self): number
  function getTexture(self, index: number): Texture
  function getTextureCount(self): number
  function getVertexBuffer(self): Buffer
  function getWidth(self): number
  function getWidth(self, mesh: number): number
  function getWidth(self, mesh: number, part: number): number
  function hasJoints(self): boolean
  function isNodeVisible(self, node: string | number): boolean
  function meshes(self): (() -> (), Model, nil)
  function resetBlendShapes(self)
  function resetNodeTransforms(self)
  function setBlendShapeWeight(self, blendshape: string | number, weight: number)
  function setNodeOrientation(self, node: string | number, angle: number, ax: number, ay: number, az: number, blend: number?)
  function setNodeOrientation(self, node: string | number, orientation: quaternion, blend: number?)
  function setNodePose(self, node: string | number, x: number, y: number, z: number, angle: number, ax: number, ay: number, az: number, blend: number?)
  function setNodePose(self, node: string | number, position: vector, orientation: quaternion, blend: number?)
  function setNodePosition(self, node: string | number, x: number, y: number, z: number, blend: number?)
  function setNodePosition(self, node: string | number, position: vector, blend: number?)
  function setNodeScale(self, node: string | number, sx: number, sy: number, sz: number, blend: number?)
  function setNodeScale(self, node: string | number, scale: vector, blend: number?)
  function setNodeTransform(self, node: string | number, x: number, y: number, z: number, sx: number, sy: number, sz: number, angle: number, ax: number, ay: number, az: number, blend: number?)
  function setNodeTransform(self, node: string | number, position: vector, scale: vector, orientation: quaternion, blend: number?)
  function setNodeTransform(self, node: string | number, transform: Mat4, blend: number?)
  function setNodeVisible(self, node: string | number, visible: boolean?)
end

declare extern type Pass extends Object with
  function barrier(self)
  function beginTally(self): number
  function box(self, x: number?, y: number?, z: number?, width: number?, height: number?, depth: number?, angle: number?, ax: number?, ay: number?, az: number?, style: DrawStyle?)
  function box(self, position: vector, size: vector, orientation: quaternion, style: DrawStyle?)
  function box(self, transform: Mat4, style: DrawStyle?)
  function capsule(self, x: number?, y: number?, z: number?, radius: number?, length: number?, angle: number?, ax: number?, ay: number?, az: number?, segments: number?)
  function capsule(self, position: vector, radius: number?, length: number?, orientation: quaternion, segments: number?)
  function capsule(self, transform: Mat4, segments: number?)
  function capsule(self, p1: vector, p2: vector, radius: number?, segments: number?)
  function circle(self, x: number?, y: number?, z: number?, radius: number?, angle: number?, ax: number?, ay: number?, az: number?, style: DrawStyle?, angle1: number?, angle2: number?, segments: number?)
  function circle(self, position: vector, radius: number?, orientation: quaternion, style: DrawStyle?, angle1: number?, angle2: number?, segments: number?)
  function circle(self, transform: Mat4, style: DrawStyle?, angle1: number?, angle2: number?, segments: number?)
  function compute(self, x: number?, y: number?, z: number?)
  function compute(self, buffer: Buffer, offset: number?)
  function cone(self, x: number?, y: number?, z: number?, radius: number?, length: number?, angle: number?, ax: number?, ay: number?, az: number?, segments: number?)
  function cone(self, position: vector, radius: number?, length: number?, orientation: quaternion, segments: number?)
  function cone(self, transform: Mat4, segments: number?)
  function cone(self, p1: vector, p2: vector, radius: number?, segments: number?)
  function cube(self, x: number?, y: number?, z: number?, size: number?, angle: number?, ax: number?, ay: number?, az: number?, style: DrawStyle?)
  function cube(self, position: vector, size: number?, orientation: quaternion, style: DrawStyle?)
  function cube(self, transform: Mat4, style: DrawStyle?)
  function cylinder(self, x: number?, y: number?, z: number?, radius: number?, length: number?, angle: number?, ax: number?, ay: number?, az: number?, capped: boolean?, angle1: number?, angle2: number?, segments: number?)
  function cylinder(self, position: vector, radius: number?, length: number?, orientation: quaternion, capped: boolean?, angle1: number?, angle2: number?, segments: number?)
  function cylinder(self, transform: Mat4, capped: boolean?, angle1: number?, angle2: number?, segments: number?)
  function cylinder(self, p1: vector, p2: vector, radius: number?, capped: boolean?, angle1: number?, angle2: number?, segments: number?)
  function draw(self, object: Model | Mesh | Texture, x: number?, y: number?, z: number?, scale: number?, angle: number?, ax: number?, ay: number?, az: number?, instances: number?)
  function draw(self, object: Model | Mesh | Texture, position: vector, scale3: vector, orientation: quaternion, instances: number?)
  function draw(self, object: Model | Mesh | Texture, transform: Mat4, instances: number?)
  function drawPart(self, model: Model, mesh: number, x: number?, y: number?, z: number?, scale: number?, angle: number?, ax: number?, ay: number?, az: number?, instances: number?)
  function drawPart(self, model: Model, mesh: number, position: vector, scale3: vector, orientation: quaternion, instances: number?)
  function drawPart(self, model: Model, mesh: number, transform: Mat4, instances: number?)
  function drawPart(self, model: Model, mesh: number, part: number, x: number?, y: number?, z: number?, scale: number?, angle: number?, ax: number?, ay: number?, az: number?, instances: number?)
  function drawPart(self, model: Model, mesh: number, part: number, position: vector, scale3: vector, orientation: quaternion, instances: number?)
  function drawPart(self, model: Model, mesh: number, part: number, transform: Mat4, instances: number?)
  function fill(self, texture: Texture?)
  function fill(self)
  function finishTally(self): number
  function getCanvas(self): { read depth: any, read samples: number }
  function getCanvas(self)
  function getClear(self): {}
  function getDimensions(self): (number, number)
  function getHeight(self): number
  function getLabel(self): string?
  function getProjection(self, view: number): (number, number, number, number)
  function getProjection(self, view: number, matrix: Mat4): Mat4
  function getStats(self): { read draws: number, read computes: number, read drawsCulled: number, read cpuMemoryReserved: number, read cpuMemoryUsed: number, read submitTime: number, read gpuTime: number }
  function getTallyBuffer(self): (Buffer, number)
  function getViewCount(self): number
  function getViewPose(self, view: number): (number, number, number, number, number, number, number)
  function getViewPose(self, view: number, matrix: Mat4, invert: boolean): Mat4
  function getViewRay(self, x: number, y: number, view: number?): (number, number, number, number, number, number)
  function getWidth(self): number
  function line(self, x1: number, y1: number, z1: number, x2: number, y2: number, z2: number, ...: number)
  function line(self, t: { read [number]: number | vector })
  function line(self, v1: vector, v2: vector, ...: vector)
  function mesh(self, vertices: Buffer?, x: number?, y: number?, z: number?, scale: number?, angle: number?, ax: number?, ay: number?, az: number?, start: number?, count: number?, instances: number?)
  function mesh(self, vertices: Buffer?, position: vector, scales: vector, orientation: quaternion, start: number?, count: number?, instances: number?)
  function mesh(self, vertices: Buffer?, transform: Mat4, start: number?, count: number?, instances: number?)
  function mesh(self, vertices: Buffer?, indices: Buffer, x: number?, y: number?, z: number?, scale: number?, angle: number?, ax: number?, ay: number?, az: number?, start: number?, count: number?, instances: number?, base: number?)
  function mesh(self, vertices: Buffer?, indices: Buffer, position: vector, scales: vector, orientation: quaternion, start: number?, count: number?, instances: number?, base: number?)
  function mesh(self, vertices: Buffer?, indices: Buffer, transform: Mat4, start: number?, count: number?, instances: number?, base: number?)
  function mesh(self, vertices: Buffer?, indices: Buffer, draws: Buffer, drawcount: number?, offset: number?, stride: number?)
  function origin(self)
  function plane(self, x: number?, y: number?, z: number?, width: number?, height: number?, angle: number?, ax: number?, ay: number?, az: number?, style: DrawStyle?, columns: number?, rows: number?)
  function plane(self, position: vector, size: vector, orientation: quaternion, style: DrawStyle?, columns: number?, rows: number?)
  function plane(self, transform: Mat4, style: DrawStyle?, columns: number?, rows: number?)
  function points(self, x: number, y: number, z: number, ...: any)
  function points(self, t: { read [number]: number | vector })
  function points(self, v: vector, ...: any)
  function polygon(self, x1: number, y1: number, z1: number, x2: number, y2: number, z2: number, ...: any)
  function polygon(self, t: { read [number]: number | vector })
  function polygon(self, v1: vector, v2: vector, ...: any)
  function pop(self, stack: StackType?)
  function push(self, stack: StackType?)
  function reset(self)
  function rotate(self, angle: number, ax: number, ay: number, az: number)
  function rotate(self, rotation: quaternion)
  function roundrect(self, x: number?, y: number?, z: number?, width: number?, height: number?, thickness: number?, angle: number?, ax: number?, ay: number?, az: number?, radius: number?, segments: number?)
  function roundrect(self, position: vector, size: vector, orientation: quaternion, radius: number?, segments: number?)
  function roundrect(self, transform: Mat4, radius: number?, segments: number?)
  function scale(self, sx: number, sy: number?, sz: number?)
  function scale(self, scale: vector)
  function send(self, name: string, buffer: Buffer, offset: number?, extent: number?)
  function send(self, name: string, texture: Texture)
  function send(self, name: string, sampler: Sampler)
  function send(self, name: string, data: any)
  function setAlphaToCoverage(self, enable: boolean?)
  function setBlendMode(self, blend: BlendMode, alphaBlend: BlendAlphaMode)
  function setBlendMode(self)
  function setBlendMode(self, index: number, blend: BlendMode, alphaBlend: BlendAlphaMode)
  function setBlendMode(self, index: number)
  function setBlendState(self, op: BlendOp, src: BlendFactor, dst: BlendFactor)
  function setBlendState(self, opColor: BlendOp, opAlpha: BlendOp, srcColor: BlendFactor, srcAlpha: BlendFactor, dstColor: BlendFactor, dstAlpha: BlendFactor)
  function setBlendState(self)
  function setBlendState(self, index: number, op: BlendOp, src: BlendFactor, dst: BlendFactor)
  function setBlendState(self, index: number, opColor: BlendOp, opAlpha: BlendOp, srcColor: BlendFactor, srcAlpha: BlendFactor, dstColor: BlendFactor, dstAlpha: BlendFactor)
  function setBlendState(self, index: number)
  function setCanvas(self, ...: Texture)
  function setCanvas(self, canvas: { read depth: any?, read samples: number? })
  function setCanvas(self)
  function setClear(self, hex: number)
  function setClear(self, r: number, g: number, b: number, a: number?)
  function setClear(self, clear: boolean)
  function setClear(self, t: {})
  function setColor(self, r: number, g: number, b: number, a: number?)
  function setColor(self, t: { read [number]: number })
  function setColor(self, hex: number, a: number?)
  function setColorWrite(self, enable: boolean?)
  function setColorWrite(self, r: boolean, g: boolean, b: boolean, a: boolean)
  function setColorWrite(self, index: number, enable: boolean?)
  function setColorWrite(self, index: number, r: boolean, g: boolean, b: boolean, a: boolean)
  function setCullMode(self, mode: CullMode?)
  function setCullMode(self)
  function setDepthClamp(self, enable: boolean?)
  function setDepthOffset(self, offset: number?, sloped: number?)
  function setDepthTest(self, test: CompareMode)
  function setDepthTest(self)
  function setDepthWrite(self, write: boolean?)
  function setFaceCull(self, mode: CullMode?)
  function setFaceCull(self)
  function setFont(self, font: Font?)
  function setMaterial(self, material: Texture | Material | nil)
  function setMaterial(self)
  function setMeshMode(self, mode: DrawMode)
  function setProjection(self, type: ProjectionType, ...: number)
  function setProjection(self, matrix: Mat4)
  function setProjection(self, view: number, type: ProjectionType, ...: number)
  function setProjection(self, view: number, matrix: Mat4)
  function setProjection(self, view: number, left: number, right: number, up: number, down: number, near: number?, far: number?)
  function setSampler(self, sampler: Sampler | FilterMode | nil)
  function setScissor(self, x: number, y: number, w: number, h: number)
  function setScissor(self)
  function setShader(self, shader: Shader | DefaultShader)
  function setShader(self)
  function setStencilTest(self, test: CompareMode, value: number, mask: number?)
  function setStencilTest(self)
  function setStencilWrite(self, action: StencilAction | { read [number]: StencilAction }, value: number?, mask: number?)
  function setStencilWrite(self)
  function setTallyBuffer(self, buffer: Buffer, offset: number?)
  function setTallyBuffer(self)
  function setViewCull(self, enable: boolean?)
  function setViewPose(self, view: number, x: number, y: number, z: number, angle: number, ax: number, ay: number, az: number)
  function setViewPose(self, view: number, position: vector, orientation: quaternion)
  function setViewPose(self, view: number, matrix: Mat4, inverted: boolean)
  function setViewport(self, x: number, y: number, w: number, h: number, dmin: number?, dmax: number?)
  function setViewport(self)
  function setWinding(self, winding: Winding)
  function setWireframe(self, enable: boolean?)
  function skybox(self, skybox: Texture?)
  function skybox(self)
  function sphere(self, x: number?, y: number?, z: number?, radius: number?, angle: number?, ax: number?, ay: number?, az: number?, longitudes: number?, latitudes: number?)
  function sphere(self, position: vector, radius: number?, orientation: quaternion, longitudes: number?, latitudes: number?)
  function sphere(self, transform: Mat4, longitudes: number?, latitudes: number?)
  function text(self, text: string, x: number?, y: number?, z: number?, scale: number?, angle: number?, ax: number?, ay: number?, az: number?, wrap: number?, halign: HorizontalAlign?, valign: VerticalAlign?)
  function text(self, text: string, position: vector, scale: number?, orientation: quaternion, wrap: number?, halign: HorizontalAlign?, valign: VerticalAlign?)
  function text(self, text: string, transform: Mat4, wrap: number?, halign: HorizontalAlign?, valign: VerticalAlign?)
  function text(self, colortext: { read [number]: any }, x: number?, y: number?, z: number?, scale: number?, angle: number?, ax: number?, ay: number?, az: number?, wrap: number?, halign: HorizontalAlign?, valign: VerticalAlign?)
  function text(self, colortext: { read [number]: any }, position: vector, scale: number?, orientation: quaternion, wrap: number?, halign: HorizontalAlign?, valign: VerticalAlign?)
  function text(self, colortext: { read [number]: any }, transform: Mat4, wrap: number?, halign: HorizontalAlign?, valign: VerticalAlign?)
  function torus(self, x: number?, y: number?, z: number?, radius: number?, thickness: number?, angle: number?, ax: number?, ay: number?, az: number?, tsegments: number?, psegments: number?)
  function torus(self, position: vector, scale: vector, orientation: quaternion, tsegments: number?, psegments: number?)
  function torus(self, transform: Mat4, tsegments: number?, psegments: number?)
  function transform(self, x: number, y: number, z: number, sx: number, sy: number, sz: number, angle: number, ax: number, ay: number, az: number)
  function transform(self, x: number, y: number, z: number, angle: number, ax: number, ay: number, az: number)
  function transform(self, translation: vector, scale: vector, rotation: quaternion)
  function transform(self, transform: Mat4)
  function translate(self, x: number, y: number, z: number)
  function translate(self, translation: vector)
end

declare extern type Raytracer with
  function add(self, mesh: Mesh, x: number?, y: number?, z: number?, scale: number?, angle: number?, ax: number?, ay: number?, az: number?, layers: number?, tag: number?): number
  function add(self, model: Model, x: number?, y: number?, z: number?, scale: number?, angle: number?, ax: number?, ay: number?, az: number?, layers: number?, tag: number?): number
  function add(self, mesh: Mesh, position: vector, scale3: vector, orientation: quaternion, layers: number?, tag: number?): number
  function add(self, model: Model, position: vector, scale3: vector, orientation: quaternion, layers: number?, tag: number?): number
  function add(self, mesh: Mesh, transform: Mat4, layers: number?, tag: number?): number
  function add(self, model: Model, transform: Mat4, layers: number?, tag: number?): number
  function build(self)
  function clear(self)
  function getCapacity(self): number
  function getCount(self): number
  function set(self, id: number, x: number?, y: number?, z: number?, scale: number?, angle: number?, ax: number?, ay: number?, az: number?, layers: number?, tag: number?)
  function set(self, id: number, position: vector, scale3: vector, orientation: quaternion, layers: number?, tag: number?)
  function set(self, id: number, transform: Mat4, layers: number?, tag: number?)
end

declare extern type Readback extends Object with
  function getBlob(self): Blob?
  function getData(self): {}?
  function getImage(self): Image?
  function isComplete(self): boolean
  function wait(self): boolean
end

declare extern type Sampler extends Object with
  function getAnisotropy(self): number
  function getCompareMode(self): CompareMode
  function getFilter(self): (FilterMode, FilterMode, FilterMode)
  function getMipmapRange(self): (number, number)
  function getWrap(self): (WrapMode, WrapMode, WrapMode)
end

declare extern type Shader extends Object with
  function clone(self, flags: {}): Shader
  function getBufferFormat(self, name: string): ({}, number)
  function getLabel(self): string?
  function getType(self): ShaderType
  function getWorkgroupSize(self): (number?, number?, number?)
  function hasAttribute(self, name: string): boolean
  function hasAttribute(self, location: number): boolean
  function hasStage(self, stage: ShaderStage): boolean
  function hasVariable(self, name: string): boolean
end

declare extern type Texture extends Object with
  function clear(self)
  function clear(self, hex: number, layer: number?, layerCount: number?, mipmap: number?, mipmapCount: number?)
  function clear(self, r: number, g: number, b: number, a: number, layer: number?, layerCount: number?, mipmap: number?, mipmapCount: number?)
  function clear(self, t: { read [number]: number }, layer: number?, layerCount: number?, mipmap: number?, mipmapCount: number?)
  function clear(self, v: vector, layer: number?, layerCount: number?, mipmap: number?, mipmapCount: number?)
  function generateMipmaps(self, base: number?, count: number?)
  function getDimensions(self): (number, number, number)
  function getFormat(self): (TextureFormat, boolean)
  function getHeight(self): number
  function getLabel(self): string?
  function getLayerCount(self): number
  function getMipmapCount(self): number
  function getPixels(self, x: number?, y: number?, layer: number?, mipmap: number?, width: number?, height: number?): Image
  function getSampleCount(self): number
  function getSampler(self): Sampler
  function getType(self): TextureType
  function getWidth(self): number
  function hasUsage(self, ...: TextureUsage): boolean
  function newReadback(self, x: number?, y: number?, layer: number?, mipmap: number?, width: number?, height: number?): Readback
  function setPixels(self, source: Texture | Image, dstx: number?, dsty: number?, dstlayer: number?, dstmipmap: number?, srcx: number?, srcy: number?, srclayer: number?, srcmipmap: number?, width: number?, height: number?, layers: number?)
  function setSampler(self, mode: FilterMode)
  function setSampler(self, sampler: Sampler)
  function setSampler(self)
end

export type GraphicsModule = {
  compileShader: (stage: ShaderStage, source: string | Blob) -> Blob,
  getBackgroundColor: () -> (number, number, number, number),
  getDefaultFont: () -> Font,
  getDevice: () -> { read id: number, read vendor: number, read name: string, read renderer: string, read subgroupSize: number, read discrete: boolean },
  getFeatures: () -> { read textureBC: boolean, read textureASTC: boolean, read wireframe: boolean, read depthClamp: boolean, read depthResolve: boolean, read raytracing: boolean, read indirectDrawFirstInstance: boolean, read float64: boolean, read int64: boolean, read int16: boolean, read cubic: boolean },
  getLimits: () -> { read textureSize2D: number, read textureSize3D: number, read textureSizeCube: number, read textureLayers: number, read renderSize: {}, read uniformBuffersPerStage: number, read storageBuffersPerStage: number, read sampledTexturesPerStage: number, read storageTexturesPerStage: number, read samplersPerStage: number, read resourcesPerShader: number, read uniformBufferRange: number, read storageBufferRange: number, read uniformBufferAlign: number, read storageBufferAlign: number, read vertexAttributes: number, read vertexBufferStride: number, read vertexShaderOutputs: number, read clipDistances: number, read cullDistances: number, read clipAndCullDistances: number, read workgroupCount: {}, read workgroupSize: {}, read totalWorkgroupSize: number, read computeSharedMemory: number, read indirectDrawCount: number, read instances: number, read anisotropy: number, read pointSize: number },
  getStats: () -> { read bufferMemory: number, read textureMemory: number, read memoryBudget: number, read memoryUsage: number },
  getWindowPass: () -> Pass?,
  isFormatSupported: (format: TextureFormat, ...TextureFeature) -> (boolean, boolean),
  isHDR: () -> boolean,
  isTimingEnabled: () -> boolean,
  newBuffer:
    & ((size: number) -> Buffer)
    & ((blob: Blob?) -> Buffer)
    & ((format: { read layout: DataLayout?, read stride: number? } | DataType, length: number?) -> Buffer)
    & ((format: { read layout: DataLayout?, read stride: number? } | DataType, data: {} | Blob | nil) -> Buffer),
  newFont:
    & ((file: string | Blob, size: number?, spread: number?) -> Font)
    & ((file: string | Blob, atlas: Image?, spread: number?) -> Font)
    & ((size: number?, spread: number?) -> Font)
    & ((rasterizer: Rasterizer, spread: number?) -> Font),
  newMaterial: (properties: { read color: { read [number]: number }?, read glow: { read [number]: number }?, read uvShift: { read [number]: number }?, read uvScale: { read [number]: number }?, read metalness: number?, read roughness: number?, read clearcoat: number?, read clearcoatRoughness: number?, read occlusionStrength: number?, read normalScale: number?, read alphaCutoff: number?, read texture: Texture?, read glowTexture: Texture?, read metalnessTexture: Texture?, read roughnessTexture: Texture?, read clearcoatTexture: Texture?, read occlusionTexture: Texture?, read normalTexture: Texture? }) -> Material,
  newMesh:
    & ((count: number, options: { read storage: MeshStorage?, read raytracer: { read dynamic: boolean?, read fasttrace: boolean?, read fastbuild: boolean?, read compress: boolean? }? }?) -> Mesh)
    & ((vertices: {}, options: { read storage: MeshStorage?, read raytracer: { read dynamic: boolean?, read fasttrace: boolean?, read fastbuild: boolean?, read compress: boolean? }? }?) -> Mesh)
    & ((blob: Blob, options: { read storage: MeshStorage?, read raytracer: { read dynamic: boolean?, read fasttrace: boolean?, read fastbuild: boolean?, read compress: boolean? }? }?) -> Mesh)
    & ((format: {}, count: number, options: { read storage: MeshStorage?, read raytracer: { read dynamic: boolean?, read fasttrace: boolean?, read fastbuild: boolean?, read compress: boolean? }? }?) -> Mesh)
    & ((format: {}, vertices: {}, options: { read storage: MeshStorage?, read raytracer: { read dynamic: boolean?, read fasttrace: boolean?, read fastbuild: boolean?, read compress: boolean? }? }?) -> Mesh)
    & ((format: {}, blob: Blob, options: { read storage: MeshStorage?, read raytracer: { read dynamic: boolean?, read fasttrace: boolean?, read fastbuild: boolean?, read compress: boolean? }? }?) -> Mesh)
    & ((buffer: Buffer) -> Mesh),
  newModel:
    & ((file: string | Blob, options: { read mipmaps: boolean?, read materials: boolean?, read raytracer: { read dynamic: boolean?, read fasttrace: boolean?, read fastbuild: boolean?, read compress: boolean? }? }?) -> Model)
    & ((modelData: ModelData, options: { read mipmaps: boolean?, read materials: boolean?, read raytracer: { read dynamic: boolean?, read fasttrace: boolean?, read fastbuild: boolean?, read compress: boolean? }? }?) -> Model),
  newPass:
    & ((...Texture) -> Pass)
    & ((canvas: { read depth: { read format: TextureFormat?, read texture: Texture }, read samples: number? }) -> Pass),
  newRaytracer: (capacity: number, options: { read dynamic: boolean?, read fasttrace: boolean?, read fastbuild: boolean?, read compress: boolean? }?) -> Raytracer,
  newSampler: (parameters: { read filter: FilterMode | { read [number]: FilterMode } | nil, read wrap: WrapMode | { read [number]: WrapMode } | nil, read compare: CompareMode?, read anisotropy: number?, read mipmaprange: {}? }) -> Sampler,
  newShader:
    & ((vertex: string | DefaultShader | Blob, fragment: string | DefaultShader | Blob, options: { read flags: {}?, read label: string?, read raw: boolean? }?) -> Shader)
    & ((compute: string | Blob, options: { read flags: {}?, read label: string?, read raw: boolean? }?) -> Shader)
    & ((defaultshader: DefaultShader, options: { read flags: {}?, read label: string?, read raw: boolean? }?) -> Shader),
  newTexture:
    & ((file: string | Blob, options: { read type: TextureType?, read format: TextureFormat?, read linear: boolean?, read samples: number?, read mipmaps: boolean | number | nil, read usage: { read [number]: TextureUsage }?, read label: string? }?) -> Texture)
    & ((width: number, height: number, options: { read type: TextureType?, read format: TextureFormat?, read linear: boolean?, read samples: number?, read mipmaps: boolean | number | nil, read usage: { read [number]: TextureUsage }?, read label: string? }?) -> Texture)
    & ((width: number, height: number, layers: number, options: { read type: TextureType?, read format: TextureFormat?, read linear: boolean?, read samples: number?, read mipmaps: boolean | number | nil, read usage: { read [number]: TextureUsage }?, read label: string? }?) -> Texture)
    & ((image: string, options: { read type: TextureType?, read format: TextureFormat?, read linear: boolean?, read samples: number?, read mipmaps: boolean | number | nil, read usage: { read [number]: TextureUsage }?, read label: string? }?) -> Texture)
    & ((images: { read [number]: string | Blob | Image }, options: { read type: TextureType?, read format: TextureFormat?, read linear: boolean?, read samples: number?, read mipmaps: boolean | number | nil, read usage: { read [number]: TextureUsage }?, read label: string? }?) -> Texture),
  newTextureView: (parent: Texture, options: { read type: TextureType?, read layer: number?, read layercount: number?, read mipmap: number?, read mipmapcount: number?, read label: string? }?) -> Texture,
  present: () -> (),
  setBackgroundColor:
    & ((r: number, g: number, b: number, a: number?) -> ())
    & ((hex: number, a: number?) -> ())
    & ((table: { read [number]: number }) -> ()),
  setTimingEnabled: (enable: boolean) -> (),
  submit:
    & ((...Pass | boolean | nil) -> boolean)
    & ((t: { read [number]: Pass | boolean }) -> boolean),
  wait: () -> (),
}

export type Device =
  | "head"
  | "floor"
  | "left"
  | "right"
  | "hand/left"
  | "hand/right"
  | "hand/left/grip"
  | "hand/right/grip"
  | "hand/left/point"
  | "hand/right/point"
  | "hand/left/pinch"
  | "hand/right/pinch"
  | "hand/left/poke"
  | "hand/right/poke"
  | "elbow/left"
  | "elbow/right"
  | "shoulder/left"
  | "shoulder/right"
  | "chest"
  | "waist"
  | "knee/left"
  | "knee/right"
  | "foot/left"
  | "foot/right"
  | "camera"
  | "keyboard"
  | "stylus"
  | "eye/left"
  | "eye/right"
  | "eye/gaze"
  | "body"

export type DeviceAxis =
  | "trigger"
  | "thumbstick"
  | "thumbrest"
  | "touchpad"
  | "grip"
  | "nib"

export type DeviceButton =
  | "trigger"
  | "thumbstick"
  | "thumbrest"
  | "thumbtap"
  | "touchpad"
  | "grip"
  | "menu"
  | "a"
  | "b"
  | "x"
  | "y"
  | "dpup"
  | "dpdown"
  | "dpleft"
  | "dpright"
  | "bumper"
  | "nib"

export type FoveationLevel =
  | "low"
  | "medium"
  | "high"

export type HeadsetDriver =
  | "simulator"
  | "openxr"

export type HeadsetOrigin =
  | "head"
  | "floor"

export type PassthroughMode =
  | "opaque"
  | "blend"
  | "add"

declare extern type Layer extends Object with
  function getColor(self): (number, number, number, number)
  function getCurve(self): number
  function getDimensions(self): (number, number)
  function getOrientation(self): (number, number, number, number)
  function getOrigin(self): Device
  function getPass(self): Pass
  function getPose(self): (number, number, number, number, number, number, number)
  function getPosition(self): (number, number, number)
  function getTexture(self): Texture
  function getViewport(self): (number, number, number, number)
  function setColor(self, r: number, g: number, b: number, a: number?)
  function setColor(self, t: { read [number]: number })
  function setColor(self, hex: number, a: number?)
  function setCurve(self, curve: number?)
  function setDimensions(self, width: number, height: number)
  function setOrientation(self, angle: number, ax: number, ay: number, az: number)
  function setOrientation(self, orientation: quaternion)
  function setOrigin(self, device: Device?)
  function setPose(self, x: number, y: number, z: number, angle: number, ax: number, ay: number, az: number)
  function setPose(self, position: vector, orientation: quaternion)
  function setPosition(self, x: number, y: number, z: number)
  function setViewport(self, x: number, y: number, w: number, h: number)
end

export type HeadsetModule = {
  animate:
    & ((model: Model) -> boolean)
    & ((device: Device?, model: Model) -> boolean),
  connect: () -> (boolean, string?),
  getAngularVelocity: (device: Device?) -> (number, number, number),
  getAxis: (device: Device?, axis: DeviceAxis) -> ...number?,
  getBattery: (device: Device?) -> (number?, boolean?),
  getBoundsDepth: () -> number,
  getBoundsDimensions: () -> (number, number),
  getBoundsWidth: () -> number,
  getClipDistance: () -> (number, number),
  getDeltaTime: () -> number,
  getDirection:
    & ((device: Device?) -> (number, number, number))
    & ((model: Model) -> (number, number, number)),
  getDisplayDimensions: () -> (number, number),
  getDisplayHeight: () -> number,
  getDisplayWidth: () -> number,
  getDriver: () -> string,
  getFeatures: () -> { read battery: boolean, read overlay: boolean, read proximity: boolean, read passthrough: boolean, read refreshRate: boolean, read depthSubmission: boolean, read eyeTracking: boolean, read handTracking: boolean, read handTrackingElbow: boolean, read keyboardTracking: boolean, read viveTrackers: boolean, read handModel: boolean, read controllerModel: boolean, read controllerSkeleton: boolean, read cubeBackground: boolean, read equirectBackground: boolean, read layerColor: boolean, read layerCurve: boolean, read layerDepthTest: boolean, read layerFilter: boolean },
  getFoveation: () -> (FoveationLevel, boolean),
  getHands: () -> {Device},
  getLayers: () -> {Layer},
  getModelKeys: () -> {lightuserdata},
  getName: () -> string,
  getOrientation:
    & ((device: Device?) -> (number, number, number, number))
    & ((model: Model) -> (number, number, number, number)),
  getPass: () -> Pass?,
  getPassthrough: () -> PassthroughMode,
  getPassthroughModes: () -> {},
  getPose:
    & ((device: Device?) -> (number, number, number, number, number, number, number))
    & ((model: Model) -> (number, number, number, number, number, number, number)),
  getPosition:
    & ((device: Device?) -> (number, number, number))
    & ((model: Model) -> (number, number, number)),
  getRefreshRate: () -> number?,
  getRefreshRates: () -> {number}?,
  getSkeleton:
    & ((device: Device) -> {{number}}?)
    & ((device: Device, t: {}) -> {{number}}?),
  getTexture: () -> Texture?,
  getTime: () -> number,
  getVelocity: (device: Device?) -> (number, number, number),
  getViewAngles: (view: number) -> (number?, number?, number?, number?),
  getViewCount: () -> number,
  getViewPose: (view: number) -> (number?, number?, number?, number?, number?, number?, number?),
  isActive: () -> boolean,
  isDown: (device: Device?, button: DeviceButton) -> boolean?,
  isFocused: () -> boolean,
  isMainSessionVisible: () -> boolean,
  isMounted: () -> boolean,
  isSeated: () -> boolean,
  isTouched: (device: Device?, button: DeviceButton) -> boolean?,
  isTracked:
    & ((device: Device?) -> boolean)
    & ((model: Model) -> boolean),
  isVisible: () -> boolean,
  newLayer:
    & ((width: number, height: number, options: { read stereo: boolean?, read static: boolean?, read transparent: boolean?, read filter: boolean? }?) -> Layer)
    & ((texture: Texture, options: { read stereo: boolean?, read static: boolean?, read transparent: boolean?, read filter: boolean? }?) -> Layer)
    & ((image: Image, options: { read stereo: boolean?, read static: boolean?, read transparent: boolean?, read filter: boolean? }?) -> Layer)
    & ((images: {}, options: { read stereo: boolean?, read static: boolean?, read transparent: boolean?, read filter: boolean? }?) -> Layer),
  newModel:
    & ((key: lightuserdata) -> Model?)
    & ((device: Device?) -> Model?),
  pollEvents: () -> (),
  setBackground:
    & ((background: Image | { read [number]: Image } | Texture) -> ())
    & (() -> ()),
  setButton: (device: Device, button: DeviceButton, down: boolean) -> (),
  setClipDistance: (near: number, far: number) -> (),
  setFoveation:
    & ((level: FoveationLevel, dynamic: boolean?) -> boolean)
    & (() -> boolean),
  setLayers:
    & ((...Layer) -> ())
    & ((t: {}) -> ()),
  setOrientation:
    & ((device: Device, angle: number, ax: number, ay: number, az: number) -> ())
    & ((device: Device, orientation: quaternion) -> ()),
  setPassthrough:
    & ((mode: PassthroughMode) -> boolean)
    & ((transparent: boolean) -> boolean)
    & (() -> boolean),
  setPose:
    & ((device: Device, x: number, y: number, z: number, angle: number, ax: number, ay: number, az: number) -> ())
    & ((device: Device, position: vector, orientation: quaternion) -> ()),
  setPosition:
    & ((device: Device, x: number, y: number, z: number) -> ())
    & ((device: Device, position: vector) -> ()),
  setRefreshRate: (rate: number) -> boolean,
  start: () -> (),
  stop: () -> (),
  stopVibration: (device: Device?) -> (),
  submit: () -> (),
  update: () -> number,
  vibrate: (device: Device?, strength: number?, duration: number?, frequency: number?) -> boolean,
  wasPressed: (device: Device, button: DeviceButton) -> boolean,
  wasReleased: (device: Device, button: DeviceButton) -> boolean,
}

declare extern type Curve extends Object with
  function addPoint(self, x: number, y: number, z: number, index: number?)
  function evaluate(self, t: number): (number, number, number)
  function getLength(self, t: number?, iterations: number?): number
  function getPoint(self, index: number): (number, number, number)
  function getPointCount(self): number
  function getTangent(self, t: number): (number, number, number)
  function removePoint(self, index: number)
  function render(self, n: number?, t1: number?, t2: number?): {number}
  function setPoint(self, index: number, x: number, y: number, z: number)
  function slice(self, t1: number, t2: number): Curve
  function step(self, distance: number, iterations: number?): number
end

declare extern type Mat4 with
  function equals(self, n: Mat4): boolean
  function fov(self, left: number, right: number, up: number, down: number, near: number, far: number?): Mat4
  function getOrientation(self): (number, number, number, number)
  function getPose(self): (number, number, number, number, number, number, number)
  function getPosition(self): (number, number, number)
  function getScale(self): (number, number, number)
  function identity(self): Mat4
  function invert(self): Mat4
  function lookAt(self, from: vector, to: vector, up: vector?): Mat4
  function mul(self, n: Mat4): Mat4
  function mul(self, x: number, y: number, z: number, w: number?): (number, number, number, number)
  function mul(self, v: vector): vector
  function orthographic(self, left: number, right: number, bottom: number, top: number, near: number, far: number): Mat4
  function orthographic(self, width: number, height: number, near: number, far: number): Mat4
  function perspective(self, fov: number, aspect: number, near: number, far: number?): Mat4
  function reflect(self, position: vector, normal: vector): Mat4
  function rotate(self, q: quaternion): Mat4
  function rotate(self, angle: number, ax: number?, ay: number?, az: number?): Mat4
  function scale(self, scale: vector): Mat4
  function scale(self, sx: number, sy: number?, sz: number?): Mat4
  function set(self): Mat4
  function set(self, n: Mat4): Mat4
  function set(self, x: number, y: number, z: number, sx: number, sy: number, sz: number, angle: number, ax: number, ay: number, az: number): Mat4
  function set(self, x: number, y: number, z: number, angle: number, ax: number, ay: number, az: number): Mat4
  function set(self, position: vector, scale: vector, rotation: quaternion): Mat4
  function set(self, position: vector, rotation: quaternion): Mat4
  function set(self, ...: number): Mat4
  function set(self, d: number): Mat4
  function setOrientation(self, angle: number, ax: number, ay: number, az: number): Mat4
  function setOrientation(self, orientation: quaternion): Mat4
  function setPose(self, x: number, y: number, z: number, angle: number, ax: number, ay: number, az: number): Mat4
  function setPose(self, position: vector, orientation: quaternion): Mat4
  function setPosition(self, x: number, y: number, z: number): Mat4
  function setPosition(self, position: vector): Mat4
  function setScale(self, sx: number?, sy: number?, sz: number?): Mat4
  function setScale(self, scale: vector): Mat4
  function target(self, from: vector, to: vector, up: vector?): Mat4
  function translate(self, v: vector): Mat4
  function translate(self, x: number, y: number, z: number): Mat4
  function transpose(self): Mat4
  function unpack(self, raw: boolean?): ...number
end

declare extern type RandomGenerator extends Object with
  function getSeed(self): (number, number)
  function getState(self): string
  function random(self): number
  function random(self, high: number): number
  function random(self, low: number, high: number): number
  function randomNormal(self, sigma: number?, mu: number?): number
  function setSeed(self, seed: number)
  function setSeed(self, low: number, high: number)
  function setState(self, state: string)
end

export type MathModule = {
  drain: () -> (),
  gammaToLinear:
    & ((gr: number, gg: number, gb: number, a: number?) -> (number, number, number, number?))
    & ((color: { read [number]: number }) -> (number, number, number, number?))
    & ((x: number) -> number),
  getRandomSeed: () -> number,
  linearToGamma:
    & ((lr: number, lg: number, lb: number, a: number?) -> (number, number, number, number?))
    & ((color: { read [number]: number }) -> (number, number, number, number?))
    & ((x: number) -> number),
  mat4:
    & ((n: Mat4) -> Mat4)
    & ((position: vector, scale: vector?, rotation: quaternion?) -> Mat4)
    & ((position: vector, rotation: quaternion?) -> Mat4)
    & ((...number) -> Mat4)
    & ((d: number) -> Mat4),
  newCurve:
    & ((x: number, y: number, z: number, ...any) -> Curve)
    & ((v: vector, ...any) -> Curve)
    & ((points: {}) -> Curve)
    & ((n: number) -> Curve),
  newMat4:
    & ((n: Mat4) -> Mat4)
    & ((position: vector, scale: vector?, rotation: quaternion?) -> Mat4)
    & ((position: vector, rotation: quaternion?) -> Mat4)
    & ((...number) -> Mat4)
    & ((d: number) -> Mat4),
  newQuat: () -> quaternion,
  newRandomGenerator:
    & (() -> RandomGenerator)
    & ((seed: number) -> RandomGenerator)
    & ((low: number, high: number) -> RandomGenerator),
  newVec2:
    & ((x: number, y: number, z: number?) -> vector)
    & ((n: number) -> vector),
  newVec3:
    & ((x: number, y: number, z: number?) -> vector)
    & ((n: number) -> vector),
  newVec4:
    & ((x: number, y: number, z: number?) -> vector)
    & ((n: number) -> vector),
  noise:
    & ((x: number) -> number)
    & ((x: number, y: number) -> number)
    & ((x: number, y: number, z: number) -> number)
    & ((x: number, y: number, z: number, w: number) -> number),
  quat: () -> quaternion,
  random:
    & (() -> number)
    & ((high: number) -> number)
    & ((low: number, high: number) -> number),
  randomNormal: (sigma: number?, mu: number?) -> number,
  setRandomSeed: (seed: number) -> (),
  vec2:
    & ((x: number, y: number, z: number?) -> vector)
    & ((n: number) -> vector),
  vec3:
    & ((x: number, y: number, z: number?) -> vector)
    & ((n: number) -> vector),
  vec4:
    & ((x: number, y: number, z: number?) -> vector)
    & ((n: number) -> vector),
}

export type JointType =
  | "ball"
  | "distance"
  | "hinge"
  | "slider"

export type MotorMode =
  | "position"
  | "velocity"

export type ShapeType =
  | "box"
  | "sphere"
  | "capsule"
  | "cylinder"
  | "convex"
  | "mesh"
  | "terrain"

declare extern type Collider extends Object with
  function addShape(self, shape: Shape)
  function applyAngularImpulse(self, x: number, y: number, z: number)
  function applyAngularImpulse(self, impulse: vector)
  function applyForce(self, x: number, y: number, z: number)
  function applyForce(self, x: number, y: number, z: number, px: number, py: number, pz: number)
  function applyForce(self, force: vector)
  function applyForce(self, force: vector, position: vector)
  function applyLinearImpulse(self, x: number, y: number, z: number)
  function applyLinearImpulse(self, x: number, y: number, z: number, px: number, py: number, pz: number)
  function applyLinearImpulse(self, impulse: vector)
  function applyLinearImpulse(self, impulse: vector, position: vector)
  function applyTorque(self, x: number, y: number, z: number)
  function applyTorque(self, torque: vector)
  function destroy(self)
  function getAABB(self): (number, number, number, number, number, number)
  function getAngularDamping(self): number
  function getAngularVelocity(self): (number, number, number)
  function getAutomaticMass(self): boolean
  function getCenterOfMass(self): (number, number, number)
  function getDegreesOfFreedom(self): (string, string)
  function getFriction(self): number
  function getGravityScale(self): number
  function getInertia(self): (number, number, number, number, number, number, number)
  function getJoints(self): {}
  function getLinearDamping(self): number
  function getLinearVelocity(self): (number, number, number)
  function getLinearVelocityFromLocalPoint(self, x: number, y: number, z: number): (number, number, number)
  function getLinearVelocityFromLocalPoint(self, point: vector): (number, number, number)
  function getLinearVelocityFromWorldPoint(self, x: number, y: number, z: number): (number, number, number)
  function getLinearVelocityFromWorldPoint(self, point: vector): (number, number, number)
  function getLocalPoint(self, wx: number, wy: number, wz: number): (number, number, number)
  function getLocalPoint(self, point: vector): (number, number, number)
  function getLocalVector(self, wx: number, wy: number, wz: number): (number, number, number)
  function getLocalVector(self, vector: vector): (number, number, number)
  function getMass(self): number
  function getOrientation(self): (number, number, number, number)
  function getPose(self): (number, number, number, number, number, number, number)
  function getPosition(self): (number, number, number)
  function getRestitution(self): number
  function getShape(self): Shape | nil
  function getShapes(self): {}
  function getTag(self): string | nil
  function getUserData(self): any
  function getWorld(self): World
  function getWorldPoint(self, x: number, y: number, z: number): (number, number, number)
  function getWorldPoint(self, point: vector): (number, number, number)
  function getWorldVector(self, x: number, y: number, z: number): (number, number, number)
  function getWorldVector(self, vector: vector): (number, number, number)
  function isAwake(self): boolean
  function isContinuous(self): boolean
  function isDestroyed(self): boolean
  function isEnabled(self): boolean
  function isGravityIgnored(self): boolean
  function isKinematic(self): boolean
  function isSensor(self): boolean
  function isSleepingAllowed(self): boolean
  function moveKinematic(self, x: number, y: number, z: number, angle: number, ax: number, ay: number, az: number, dt: number)
  function moveKinematic(self, position: vector, orientation: quaternion, dt: number)
  function removeShape(self, shape: Shape)
  function resetMassData(self)
  function setAngularDamping(self, damping: number)
  function setAngularVelocity(self, vx: number, vy: number, vz: number)
  function setAngularVelocity(self, velocity: vector)
  function setAutomaticMass(self, enable: boolean?)
  function setAwake(self, awake: boolean?)
  function setCenterOfMass(self, x: number, y: number, z: number)
  function setCenterOfMass(self, center: vector)
  function setContinuous(self, continuous: boolean?)
  function setDegreesOfFreedom(self, translation: string?, rotation: string?)
  function setEnabled(self, enable: boolean?)
  function setFriction(self, friction: number)
  function setGravityIgnored(self, ignored: boolean)
  function setGravityScale(self, scale: number)
  function setInertia(self, dx: number, dy: number, dz: number, angle: number, ax: number, ay: number, az: number)
  function setInertia(self, diagonal: vector, rotation: quaternion)
  function setKinematic(self, kinematic: boolean)
  function setLinearDamping(self, damping: number)
  function setLinearVelocity(self, vx: number, vy: number, vz: number)
  function setLinearVelocity(self, velocity: vector)
  function setMass(self, mass: number)
  function setOrientation(self, angle: number, ax: number, ay: number, az: number)
  function setOrientation(self, orientation: quaternion)
  function setPose(self, x: number, y: number, z: number, angle: number, ax: number, ay: number, az: number)
  function setPose(self, position: vector, orientation: quaternion)
  function setPosition(self, x: number, y: number, z: number)
  function setPosition(self, position: vector)
  function setRestitution(self, restitution: number)
  function setSensor(self, sensor: boolean?)
  function setSleepingAllowed(self, sleepy: boolean?)
  function setTag(self, tag: string)
  function setTag(self)
  function setUserData(self, data: any)
end

declare extern type Contact with
  function getColliders(self): (Collider, Collider)
  function getFriction(self): number
  function getNormal(self): (number, number, number)
  function getOverlap(self): number
  function getPoints(self): ...number
  function getRestitution(self): number
  function getShapes(self): (Shape, Shape)
  function getSurfaceVelocity(self): (number, number, number)
  function isEnabled(self): boolean
  function setEnabled(self, enable: boolean)
  function setFriction(self, friction: number)
  function setRestitution(self, restitution: number)
  function setSurfaceVelocity(self, x: number, y: number, z: number)
  function setSurfaceVelocity(self, velocity: vector)
end

declare extern type Joint extends Object with
  function destroy(self)
  function getAnchors(self): (number, number, number, number, number, number)
  function getColliders(self): (Collider, Collider)
  function getForce(self): number
  function getPriority(self): number
  function getTorque(self): number
  function getType(self): JointType
  function getUserData(self): any
  function isDestroyed(self): boolean
  function isEnabled(self): boolean
  function setEnabled(self, enabled: boolean)
  function setPriority(self, priority: number)
  function setUserData(self, data: any)
end

declare extern type Shape extends Object with
  function containsPoint(self, x: number, y: number, z: number): boolean
  function containsPoint(self, point: vector): boolean
  function destroy(self)
  function getAABB(self): (number, number, number, number, number, number)
  function getCenterOfMass(self): (number, number, number)
  function getCollider(self): Collider
  function getDensity(self): number
  function getInertia(self): (number, number, number, number, number, number, number)
  function getMass(self): number
  function getOffset(self): (number, number, number, number, number, number, number)
  function getOrientation(self): (number, number, number, number)
  function getPose(self): (number, number, number, number, number, number, number)
  function getPosition(self): (number, number, number)
  function getType(self): ShapeType
  function getUserData(self): any
  function getVolume(self): number
  function isDestroyed(self): boolean
  function raycast(self, x1: number, y1: number, z1: number, x2: number, y2: number, z2: number): (number, number, number, number, number, number, number | nil)
  function raycast(self, origin: vector, endpoint: vector): (number, number, number, number, number, number, number | nil)
  function setDensity(self, density: number)
  function setOffset(self, x: number, y: number, z: number, angle: number, ax: number, ay: number, az: number)
  function setOffset(self, position: vector, rotation: quaternion)
  function setUserData(self, data: any)
end

declare extern type SliderJoint extends Joint with
  function getAxis(self): (number, number, number)
  function getFriction(self): number
  function getLimits(self): (number, number)
  function getMaxMotorForce(self): (number, number)
  function getMotorForce(self): number
  function getMotorMode(self): MotorMode
  function getMotorSpring(self): (number, number)
  function getMotorTarget(self): number
  function getPosition(self): number
  function getSpring(self): (number, number)
  function setFriction(self, friction: number)
  function setLimits(self, min: number, max: number)
  function setLimits(self)
  function setMaxMotorForce(self, positive: number?, negative: number?)
  function setMotorMode(self, mode: MotorMode)
  function setMotorMode(self)
  function setMotorSpring(self, frequency: number?, damping: number?)
  function setMotorTarget(self, target: number)
  function setSpring(self, frequency: number?, damping: number?)
end

declare extern type SphereShape extends Shape with
  function getRadius(self): number
  function setRadius(self, radius: number)
end

declare extern type TerrainShape extends Shape with
end

declare extern type WeldJoint extends Joint with
end

declare extern type World extends Object with
  function destroy(self)
  function disableCollisionBetween(self, tag1: string, tag2: string)
  function enableCollisionBetween(self, tag1: string, tag2: string)
  function getAngularDamping(self): (number, number)
  function getCallbacks(self): ({ read filter: (() -> ())?, read enter: (() -> ())?, read exit: (() -> ())?, read contact: (() -> ())? })
  function getColliderCount(self): number
  function getColliders(self): {Collider}
  function getGravity(self): (number, number, number)
  function getJointCount(self): number
  function getJoints(self): {Joint}
  function getLinearDamping(self): (number, number)
  function getResponseTime(self): number
  function getStepCount(self): number
  function getTags(self): {string}
  function getTightness(self): number
  function interpolate(self, alpha: number)
  function isCollisionEnabledBetween(self, tag1: string, tag2: string): boolean
  function isDestroyed(self): boolean
  function isSleepingAllowed(self): boolean
  function newBoxCollider(self, x: number?, y: number?, z: number?, width: number?, height: number?, depth: number?): Collider
  function newBoxCollider(self, position: vector?, size: vector?): Collider
  function newCapsuleCollider(self, x: number?, y: number?, z: number?, radius: number?, length: number?): Collider
  function newCapsuleCollider(self, position: vector?, radius: number?, length: number?): Collider
  function newCollider(self, x: number, y: number, z: number): Collider
  function newCollider(self, position: vector): Collider
  function newConvexCollider(self, x: number?, y: number?, z: number?, points: {}, scale: vector?): Collider
  function newConvexCollider(self, position: vector?, points: {}, scale: vector?): Collider
  function newConvexCollider(self, x: number?, y: number?, z: number?, modelData: ModelData, scale: vector?): Collider
  function newConvexCollider(self, position: vector?, modelData: ModelData, scale: vector?): Collider
  function newConvexCollider(self, x: number?, y: number?, z: number?, mesh: Mesh, scale: vector?): Collider
  function newConvexCollider(self, position: vector?, mesh: Mesh, scale: vector?): Collider
  function newConvexCollider(self, x: number?, y: number?, z: number?, template: ConvexShape, scale: vector?): Collider
  function newConvexCollider(self, position: vector?, template: ConvexShape, scale: vector?): Collider
  function newCylinderCollider(self, x: number?, y: number?, z: number?, radius: number?, length: number?): Collider
  function newCylinderCollider(self, position: vector?, radius: number?, length: number?): Collider
  function newMeshCollider(self, vertices: {}, indices: {}, scale: vector?): Collider
  function newMeshCollider(self, modelData: ModelData, scale: vector?): Collider
  function newMeshCollider(self, mesh: Mesh, scale: vector?): Collider
  function newMeshCollider(self, template: MeshShape, scale: vector?): Collider
  function newSphereCollider(self, x: number?, y: number?, z: number?, radius: number?): Collider
  function newSphereCollider(self, position: vector?, radius: number?): Collider
  function newTerrainCollider(self, scale: number): Collider
  function newTerrainCollider(self, scale: number, heightmap: Image, stretch: number?): Collider
  function newTerrainCollider(self, scale: number, callback: (x: number, z: number) -> number, samples: number?): Collider
  function overlapShape(self, shape: Shape, x: number, y: number, z: number, angle: number, ax: number, ay: number, az: number, maxDistance: number?, filter: string?, callback: () -> ())
  function overlapShape(self, shape: Shape, position: vector, orientation: quaternion, maxDistance: number?, filter: string?, callback: () -> ())
  function overlapShape(self, shape: Shape, x: number, y: number, z: number, angle: number, ax: number, ay: number, az: number, maxDistance: number?, filter: string?): (Collider, Shape, number, number, number, number, number, number, number | nil)
  function overlapShape(self, shape: Shape, position: vector, orientation: quaternion, maxDistance: number?, filter: string?): (Collider, Shape, number, number, number, number, number, number, number | nil)
  function queryBox(self, x: number, y: number, z: number, width: number, height: number, depth: number, filter: string?, callback: () -> ())
  function queryBox(self, position: vector, size: vector, filter: string?, callback: () -> ())
  function queryBox(self, x: number, y: number, z: number, width: number, height: number, depth: number, filter: string?): Collider
  function queryBox(self, position: vector, size: vector, filter: string?): Collider
  function querySphere(self, x: number, y: number, z: number, radius: number, filter: string?, callback: () -> ())
  function querySphere(self, position: vector, radius: number, filter: string?, callback: () -> ())
  function querySphere(self, x: number, y: number, z: number, radius: number, filter: string?): Collider
  function querySphere(self, position: vector, radius: number, filter: string?): Collider
  function raycast(self, x1: number, y1: number, z1: number, x2: number, y2: number, z2: number, filter: string?, callback: (collider: Collider, shape: Shape, x: number, y: number, z: number, nx: number, ny: number, nz: number, triangle: number, fraction: number) -> number?)
  function raycast(self, origin: vector, endpoint: vector, filter: string?, callback: (collider: Collider, shape: Shape, x: number, y: number, z: number, nx: number, ny: number, nz: number, triangle: number, fraction: number) -> number?)
  function raycast(self, x1: number, y1: number, z1: number, x2: number, y2: number, z2: number, filter: string?): (Collider, Shape, number, number, number, number, number, number, number | nil)
  function raycast(self, origin: vector, endpoint: vector, filter: string?): (Collider, Shape, number, number, number, number, number, number, number | nil)
  function setAngularDamping(self, damping: number, threshold: number?)
  function setCallbacks(self, callbacks: { read filter: (() -> ())?, read enter: (() -> ())?, read exit: (() -> ())?, read contact: (() -> ())? })
  function setGravity(self, xg: number, yg: number, zg: number)
  function setGravity(self, gravity: vector)
  function setLinearDamping(self, damping: number, threshold: number?)
  function setResponseTime(self, responseTime: number)
  function setSleepingAllowed(self, allowed: boolean?)
  function setStepCount(self, steps: number)
  function setTightness(self, tightness: number)
  function shapecast(self, shape: Shape, x1: number, y1: number, z1: number, x2: number, y2: number, z2: number, angle: number, ax: number, ay: number, az: number, filter: string?, callback: (collider: Collider, shape: Shape, x: number, y: number, z: number, nx: number, ny: number, nz: number, triangle: number, fraction: number) -> number?)
  function shapecast(self, shape: Shape, position: vector, destination: vector, orientation: quaternion, filter: string?, callback: (collider: Collider, shape: Shape, x: number, y: number, z: number, nx: number, ny: number, nz: number, triangle: number, fraction: number) -> number?)
  function shapecast(self, shape: Shape, x1: number, y1: number, z1: number, x2: number, y2: number, z2: number, angle: number, ax: number, ay: number, az: number, filter: string?): (Collider, Shape, number, number, number, number, number, number, number, number)
  function shapecast(self, shape: Shape, position: vector, destination: vector, orientation: quaternion, filter: string?): (Collider, Shape, number, number, number, number, number, number, number, number)
  function update(self, dt: number)
end

declare extern type BallJoint extends Joint with
end

declare extern type BoxShape extends Shape with
  function getDimensions(self): (number, number, number)
  function setDimensions(self, width: number, height: number, depth: number)
end

declare extern type CapsuleShape extends Shape with
  function getLength(self): number
  function getRadius(self): number
  function setLength(self, length: number)
  function setRadius(self, radius: number)
end

declare extern type ConeJoint extends Joint with
  function getAxis(self): (number, number, number)
  function getLimit(self): number
  function setLimit(self, limit: number)
end

declare extern type ConvexShape extends Shape with
  function getFace(self, index: number): {}
  function getFaceCount(self): number
  function getPoint(self, index: number): (number, number, number)
  function getPointCount(self): number
  function getScale(self): number
end

declare extern type CylinderShape extends Shape with
  function getLength(self): number
  function getRadius(self): number
  function setLength(self, length: number)
  function setRadius(self, radius: number)
end

declare extern type DistanceJoint extends Joint with
  function getLimits(self): (number, number)
  function getSpring(self): (number, number)
  function setLimits(self, min: number?, max: number?)
  function setLimits(self)
  function setSpring(self, frequency: number?, damping: number?)
end

declare extern type HingeJoint extends Joint with
  function getAngle(self): number
  function getAxis(self): (number, number, number)
  function getFriction(self): number
  function getLimits(self): (number, number)
  function getMaxMotorTorque(self): (number, number)
  function getMotorMode(self): MotorMode
  function getMotorSpring(self): (number, number)
  function getMotorTarget(self): number
  function getMotorTorque(self): number
  function getSpring(self): (number, number)
  function setFriction(self, friction: number)
  function setLimits(self, min: number, max: number)
  function setLimits(self)
  function setMaxMotorTorque(self, positive: number?, negative: number?)
  function setMotorMode(self, mode: MotorMode)
  function setMotorMode(self)
  function setMotorSpring(self, frequency: number?, damping: number?)
  function setMotorTarget(self, target: number)
  function setSpring(self, frequency: number?, damping: number?)
end

declare extern type MeshShape extends Shape with
  function getScale(self): number
end

export type PhysicsModule = {
  newBallJoint:
    & ((colliderA: Collider?, colliderB: Collider, x: number?, y: number?, z: number?) -> BallJoint)
    & ((colliderA: Collider?, colliderB: Collider, anchor: vector?) -> BallJoint),
  newBoxShape: (width: number?, height: number?, depth: number?) -> BoxShape,
  newCapsuleShape: (radius: number?, length: number?) -> CapsuleShape,
  newConeJoint:
    & ((colliderA: Collider?, colliderB: Collider, x: number?, y: number?, z: number?, ax: number?, ay: number?, az: number?) -> ConeJoint)
    & ((colliderA: Collider?, colliderB: Collider, anchor: vector?, axis: vector?) -> ConeJoint),
  newConvexShape:
    & ((points: {}, scale: vector?) -> ConvexShape)
    & ((object: ModelData | Mesh, scale: vector?) -> ConvexShape)
    & ((template: ConvexShape, scale: vector?) -> ConvexShape),
  newCylinderShape: (radius: number?, length: number?) -> CylinderShape,
  newDistanceJoint:
    & ((colliderA: Collider?, colliderB: Collider, x1: number?, y1: number?, z1: number?, x2: number?, y2: number?, z2: number?) -> DistanceJoint)
    & ((colliderA: Collider?, colliderB: Collider, first: vector?, second: vector?) -> DistanceJoint),
  newHingeJoint:
    & ((colliderA: Collider?, colliderB: Collider, x: number?, y: number?, z: number?, ax: number?, ay: number?, az: number?) -> HingeJoint)
    & ((colliderA: Collider?, colliderB: Collider, anchor: vector?, axis: vector?) -> HingeJoint),
  newMeshShape:
    & ((vertices: {}, indices: {}, scale: vector?) -> MeshShape)
    & ((object: ModelData | Mesh, scale: vector?) -> MeshShape)
    & ((template: MeshShape, scale: vector?) -> MeshShape),
  newSliderJoint:
    & ((colliderA: Collider?, colliderB: Collider, ax: number?, ay: number?, az: number?) -> SliderJoint)
    & ((colliderA: Collider?, colliderB: Collider, axis: vector?) -> SliderJoint),
  newSphereShape: (radius: number?) -> SphereShape,
  newTerrainShape:
    & ((scale: number) -> TerrainShape)
    & ((scale: number, heightmap: Image, stretch: number?) -> TerrainShape)
    & ((scale: number, callback: (x: number, z: number) -> (), samples: number?) -> TerrainShape),
  newWeldJoint: (colliderA: Collider?, colliderB: Collider) -> WeldJoint,
  newWorld: (settings: { read tags: {}?, read staticTags: {}?, read maxColliders: number?, read threadSafe: boolean?, read allowSleep: boolean?, read stabilization: number?, read maxOverlap: number?, read restitutionThreshold: number?, read velocitySteps: number?, read positionSteps: number? }?) -> World,
}

export type MouseMode =
  | "normal"
  | "relative"

export type Permission =
  | "audiocapture"

export type SystemModule = {
  getClipboardText: () -> string | nil,
  getCoreCount: () -> number,
  getMouseMode: () -> MouseMode,
  getMousePosition: () -> (number, number),
  getMouseX: () -> number,
  getMouseY: () -> number,
  getOS: () -> string,
  getWindowDensity: () -> number,
  getWindowDimensions: () -> (number, number),
  getWindowHeight: () -> number,
  getWindowWidth: () -> number,
  hasKeyRepeat: () -> boolean,
  isKeyDown: (...KeyCode) -> boolean,
  isMouseDown: (button: number) -> boolean,
  isWindowFocused: () -> boolean,
  isWindowFullscreen: () -> boolean,
  isWindowOpen: () -> boolean,
  isWindowVisible: () -> boolean,
  openWindow: (options: { read width: number?, read height: number?, read fullscreen: boolean?, read resizable: boolean?, read title: string?, read icon: string? }) -> (),
  pollEvents: (timeout: number?) -> (),
  requestPermission: (permission: Permission) -> (),
  setClipboardText: (text: string) -> (),
  setKeyRepeat: (enable: boolean) -> (),
  setMouseMode: (mode: MouseMode) -> (),
  setWindowFullscreen: (fullscreen: boolean) -> (),
  wasKeyPressed: (...KeyCode) -> boolean,
  wasKeyReleased: (...KeyCode) -> boolean,
  wasMousePressed: (button: number) -> boolean,
  wasMouseReleased: (button: number) -> boolean,
}

export type TaskModule = {
  getStatus: (task: thread) -> string | nil,
  poll: () -> (() -> ()),
  resume: (...any) -> (boolean, ...any),
  start: (f: () -> (), ...any) -> thread,
  wait:
    & ((...thread) -> ...any)
    & ((t: { read [number]: thread }) -> ...any),
}

declare extern type Channel extends Object with
  function clear(self)
  function getCount(self): number
  function hasRead(self, id: number): boolean
  function peek(self): (any, boolean)
  function pop(self, wait: number | boolean | nil): any
  function push(self, message: any, wait: number | boolean | nil): (number, boolean)
end

declare extern type Thread extends Object with
  function getError(self): string?
  function isRunning(self): boolean
  function start(self, ...: any)
  function wait(self)
end

export type ThreadModule = {
  call: (f: () -> (), ...any) -> ...any,
  getChannel: (name: string) -> Channel,
  getWorkerCount: () -> number,
  newChannel: () -> Channel,
  newThread:
    & ((code: string) -> Thread)
    & ((file: string | Blob) -> Thread),
}

export type TimerModule = {
  getAverageDelta: () -> number,
  getDelta: () -> number,
  getFPS: () -> number,
  getTime: () -> number,
  sleep: (duration: number) -> (),
  step: () -> number,
}

export type QuaternionModule = {
  angleaxis: (angle: number, ax: number, ay: number, az: number) -> quaternion,
  between: (a: vector, b: vector) -> quaternion,
  conjugate: (q: quaternion) -> quaternion,
  direction: (q: quaternion) -> vector,
  euler: (pitch: number, yaw: number, roll: number) -> quaternion,
  lookdir: (direction: vector, up: vector?) -> quaternion,
  pack:
    & ((x: number, y: number, z: number, w: number) -> quaternion)
    & (() -> quaternion),
  slerp: (a: quaternion, b: vector, t: number) -> quaternion,
  toangleaxis: (q: quaternion) -> (number, number, number, number),
  toeuler: (q: quaternion) -> (number, number, number),
  unpack: (q: quaternion) -> (number, number, number, number),
}

export type VectorModule = {
  angle: (a: vector, b: vector, axis: vector?) -> number,
  cross: (a: vector, b: vector) -> vector,
  distance: (a: vector, b: vector) -> number,
  dot: (a: vector, b: vector) -> number,
  length: (v: vector) -> number,
  lerp: (a: vector, b: vector, t: number) -> vector,
  normalize: (v: vector) -> vector,
  pack:
    & ((x: number, y: number, z: number?) -> vector)
    & ((n: number) -> vector),
  rotate: (v: vector, q: quaternion) -> number,
  unpack: (v: vector) -> (number, number, number),
}

export type LovrConfiguration = { version: string, identity: string, saveprecedence: boolean, modules: { audio: boolean, data: boolean, event: boolean, graphics: boolean, headset: boolean, math: boolean, physics: boolean, system: boolean, task: boolean, thread: boolean, timer: boolean }, audio: { debug: boolean, samplerate: number?, read start: boolean, write start: boolean?, read reverb: { type: "none" | "convolution" | "parametric", rays: number, bounces: number, duration: number, rate: number }, write reverb: { type: "none" | "convolution" | "parametric", rays: number, bounces: number, duration: number, rate: number }? }, graphics: { debug: boolean, vsync: boolean, stencil: boolean, antialias: boolean, lowpower: boolean, hdr: boolean, shadercache: boolean }, headset: { backend: "auto" | "openxr" | "openvr", connect: boolean, start: boolean, debug: boolean, read supersample: boolean, write supersample: boolean | number | nil, seated: boolean, read mask: boolean, write mask: boolean?, read antialias: boolean, write antialias: boolean?, stencil: boolean, read dynamicresolution: boolean, write dynamicresolution: boolean?, submitdepth: boolean, read overlay: boolean, write overlay: boolean | number, read controllerskeleton: "none" | "controller" | "natural", write controllerskeleton: "none" | "controller" | "natural" | nil, extensions: {string}? }, math: { globals: boolean }, thread: { read workers: number, write workers: number? }, read window: { read width: number, write width: number?, read height: number, write height: number?, centered: boolean, fullscreen: boolean, resizable: boolean, read title: string, write title: string?, icon: string | Blob | Image | nil }, write window: { read width: number, write width: number?, read height: number, write height: number?, centered: boolean, fullscreen: boolean, resizable: boolean, read title: string, write title: string?, icon: string | Blob | Image | nil }? }

declare lovr: {
  getVersion: () -> (number, number, number, string, string),

  conf: ((t: LovrConfiguration) -> ())?,
  draw: ((pass: Pass) -> boolean?)?,
  errhand: ((message: string) -> (() -> any)?)?,
  filechanged: ((path: string, action: FileAction, oldpath: string?) -> ())?,
  focus: ((focused: boolean, display: DisplayType) -> ())?,
  keypressed: ((key: KeyCode, scancode: number, isrepeat: boolean, modifiers: { read shift: boolean, read control: boolean, read alt: boolean, read super: boolean, read capsLock: boolean, read numLock: boolean }?) -> ())?,
  keyreleased: ((key: KeyCode, scancode: number, modifiers: { read shift: boolean, read control: boolean, read alt: boolean, read super: boolean, read capsLock: boolean, read numLock: boolean }?) -> ())?,
  load: ((arg: {}) -> ())?,
  log: ((message: string, level: string, tag: string) -> ())?,
  mirror: ((pass: Pass) -> boolean?)?,
  modelschanged: (() -> ())?,
  mount: ((mounted: boolean) -> ())?,
  mousemoved: ((x: number, y: number, dx: number, dy: number) -> ())?,
  mousepressed: ((x: number, y: number, button: number) -> ())?,
  mousereleased: ((x: number, y: number, button: number) -> ())?,
  permission: ((permission: Permission, granted: boolean) -> ())?,
  quit: (() -> boolean?)?,
  recenter: (() -> ())?,
  resize: ((width: number, height: number) -> ())?,
  restart: (() -> any)?,
  run: (() -> (() -> any))?,
  simulate: ((dt: number) -> ())?,
  taskready: ((task: thread) -> ())?,
  textinput: ((text: string, code: number) -> ())?,
  threaderror: ((thread: Thread, message: string) -> ())?,
  update: ((dt: number) -> ())?,
  visible: ((visible: boolean, display: DisplayType) -> ())?,
  wheelmoved: ((dx: number, dy: number) -> ())?,

  audio: AudioModule,
  data: DataModule,
  event: EventModule,
  filesystem: FilesystemModule,
  graphics: GraphicsModule,
  headset: HeadsetModule,
  math: MathModule,
  physics: PhysicsModule,
  system: SystemModule,
  task: TaskModule,
  thread: ThreadModule,
  timer: TimerModule,
}

declare extern type quaternion with
  x: number
  y: number
  z: number
  w: number
  function __mul(self, other: quaternion): quaternion
  function __mul(self, other: vector): vector
  function angleaxis(self, ax: number, ay: number, az: number): quaternion
  function between(self, b: vector): quaternion
  function conjugate(self): quaternion
  function direction(self): vector
  function euler(self, yaw: number, roll: number): quaternion
  function lookdir(self, up: vector?): quaternion
  function pack(self, y: number, z: number, w: number): quaternion
  function slerp(self, b: vector, t: number): quaternion
  function toangleaxis(self): (number, number, number, number)
  function toeuler(self): (number, number, number)
  function unpack(self): (number, number, number, number)
end

declare quaternion: QuaternionModule
  & ((x: number, y: number, z: number, w: number) -> quaternion)
  & (() -> quaternion)

declare extern type vector with
  x: number
  y: number
  z: number
  function __add(self, other: vector): vector
  function __sub(self, other: vector): vector
  function __mul(self, other: vector): vector
  function __mul(self, other: number): vector
  function __div(self, other: vector): vector
  function __div(self, other: number): vector
  function __unm(self): vector
  function angle(self, b: vector, axis: vector?): number
  function cross(self, b: vector): vector
  function distance(self, b: vector): number
  function dot(self, b: vector): number
  function length(self): number
  function lerp(self, b: vector, t: number): vector
  function normalize(self): vector
  function pack(self, y: number, z: number?): vector
  function pack(self): vector
  function rotate(self, q: quaternion): number
  function unpack(self): (number, number, number)
end

declare vector: VectorModule
  & ((x: number, y: number, z: number?) -> vector)
  & ((n: number) -> vector)