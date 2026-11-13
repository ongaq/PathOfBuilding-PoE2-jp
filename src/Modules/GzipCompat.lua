-- Path of Building
--
-- Module: Gzip Compat
-- フォーク専用の互換レイヤ。
-- 日本語対応版のSimpleGraphic.dllはv2.5.3ベースのため、v2.5.5で追加された
-- Deflate(data, true)によるGzip出力と、InflateのGzip入力の自動判別を持たない。
-- 旧版のDeflateは第2引数を無視してZLib形式で出力し、InflateはZLib形式しか展開できない。
-- ネイティブがGzipに対応していない場合に限り、グローバルのDeflate/Inflateを包んで補う。
-- SimpleGraphic.dllをv2.5.5以降ベースで再ビルドすれば、起動時の判定で自動的に無効になる。
--
local nativeDeflate, nativeInflate = Deflate, Inflate
if type(nativeDeflate) ~= "function" or type(nativeInflate) ~= "function" then
	return
end

local bit = require("bit")
local band, bxor, bnot, rshift = bit.band, bit.bxor, bit.bnot, bit.rshift
local s_byte, s_char = string.byte, string.char

-- Gzipヘッダ(10バイト)とトレーラ(8バイト)を含む最小長
local GZIP_MIN_LEN = 18

local function isGzip(data)
	return type(data) == "string" and #data >= GZIP_MIN_LEN and s_byte(data, 1) == 0x1f and s_byte(data, 2) == 0x8b
end

-- 旧版のZLib出力が返ってきた場合のみ有効にする。
-- Gzip対応済みのネイティブ実装や、ヘッドレス環境のスタブ(空文字列を返す)では何もしない。
-- ZLibヘッダの1バイト目(CMF)は下位4ビットが8(deflate)で、CMF*256+FLGが31の倍数になる。
local probe = nativeDeflate("a", true)
if type(probe) ~= "string" or #probe < 6 or band(s_byte(probe, 1), 0x0F) ~= 8 or (s_byte(probe, 1) * 256 + s_byte(probe, 2)) % 31 ~= 0 then
	return
end

local crcTable
local function crc32(str)
	if not crcTable then
		crcTable = { }
		for n = 0, 255 do
			local c = n
			for _ = 1, 8 do
				if band(c, 1) ~= 0 then
					c = bxor(0xEDB88320, rshift(c, 1))
				else
					c = rshift(c, 1)
				end
			end
			crcTable[n] = c
		end
	end
	local crc = bnot(0)
	for i = 1, #str do
		crc = bxor(rshift(crc, 8), crcTable[band(bxor(crc, s_byte(str, i)), 0xFF)])
	end
	return bnot(crc)
end

local function u32le(n)
	return s_char(band(n, 0xFF), band(rshift(n, 8), 0xFF), band(rshift(n, 16), 0xFF), band(rshift(n, 24), 0xFF))
end

-- ID1, ID2, CM=8(deflate), FLG=0, MTIME=0, XFL=2(最大圧縮), OS=255(不明)
local GZIP_HEADER = "\31\139\8\0\0\0\0\0\2\255"

function Deflate(data, useGzip)
	if not useGzip then
		return nativeDeflate(data)
	end
	local zlibData, errMsg = nativeDeflate(data)
	if type(zlibData) ~= "string" or #zlibData < 6 then
		return nil, errMsg or "Deflate failed"
	end
	-- ZLib形式は「2バイトのヘッダ + 生DEFLATE + Adler-32(4バイト)」。旧版はプリセット辞書を使わないためヘッダは常に2バイト。
	-- 生DEFLATE部分を取り出し、Gzipのヘッダと「CRC-32 + 元データ長」のトレーラで包み直す。
	return GZIP_HEADER .. zlibData:sub(3, -5) .. u32le(crc32(data)) .. u32le(#data % 4294967296)
end

-- Gzipの展開はAdler-32を事前に計算できず旧版のInflateで代用できないため、
-- LuaJIT FFI経由でruntime/zlib1.dllのinflateを直接呼ぶ
local ffi, zlib, zlibErr
local function loadZlib()
	if zlib or zlibErr then
		return zlib, zlibErr
	end
	local ok, result = pcall(require, "ffi")
	if not ok then
		zlibErr = "FFI unavailable: " .. tostring(result)
		return nil, zlibErr
	end
	ffi = result
	-- 他モジュールとの型名衝突を避けるため独自の名前で宣言する。Windowsのunsigned longは32ビット。
	pcall(ffi.cdef, [[
		typedef struct pobGzipCompat_z_stream {
			const unsigned char *next_in;
			unsigned int avail_in;
			unsigned long total_in;
			unsigned char *next_out;
			unsigned int avail_out;
			unsigned long total_out;
			const char *msg;
			void *state;
			void *zalloc;
			void *zfree;
			void *opaque;
			int data_type;
			unsigned long adler;
			unsigned long reserved;
		} pobGzipCompat_z_stream;
		const char *zlibVersion(void);
		int inflateInit2_(pobGzipCompat_z_stream *strm, int windowBits, const char *version, int stream_size);
		int inflate(pobGzipCompat_z_stream *strm, int flush);
		int inflateEnd(pobGzipCompat_z_stream *strm);
	]])
	local loaded
	ok, loaded = pcall(ffi.load, "zlib1")
	if not ok then
		zlibErr = "Failed to load zlib1.dll: " .. tostring(loaded)
		return nil, zlibErr
	end
	zlib = loaded
	return zlib
end

local Z_OK, Z_STREAM_END, Z_NO_FLUSH = 0, 1, 0
-- 15 + 32でZLib/Gzipヘッダを自動判別(v2.5.5以降のネイティブ実装と同じ)
local INFLATE_WINDOW_BITS = 15 + 32
-- ネイティブ実装と同じく128MiBを上限とする
local MAX_OUTPUT_LEN = 128 * 1024 * 1024

local function inflateGzip(data)
	local lib, errMsg = loadZlib()
	if not lib then
		return nil, errMsg
	end
	local strm = ffi.new("pobGzipCompat_z_stream")
	local ret = lib.inflateInit2_(strm, INFLATE_WINDOW_BITS, lib.zlibVersion(), ffi.sizeof(strm))
	if ret ~= Z_OK then
		return nil, "inflateInit2 failed (" .. ret .. ")"
	end
	local inLen = #data
	local inBuf = ffi.new("unsigned char[?]", inLen)
	ffi.copy(inBuf, data, inLen)
	strm.next_in = inBuf
	strm.avail_in = inLen
	local chunkLen = math.max(inLen * 4, 16384)
	local chunk = ffi.new("unsigned char[?]", chunkLen)
	local parts, total = { }, 0
	repeat
		strm.next_out = chunk
		strm.avail_out = chunkLen
		ret = lib.inflate(strm, Z_NO_FLUSH)
		local produced = chunkLen - strm.avail_out
		if produced > 0 then
			parts[#parts + 1] = ffi.string(chunk, produced)
			total = total + produced
		end
	until ret ~= Z_OK or total > MAX_OUTPUT_LEN
	lib.inflateEnd(strm)
	if ret ~= Z_STREAM_END then
		return nil, total > MAX_OUTPUT_LEN and "Output larger than 128 MiB" or ("Inflate failed (" .. ret .. ")")
	end
	return table.concat(parts)
end

function Inflate(data)
	if isGzip(data) then
		return inflateGzip(data)
	end
	return nativeInflate(data)
end
