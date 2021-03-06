__precompile__()
"""
    WebSockets
This module implements the server side of the WebSockets protocol. Some
things would need to be added to implement a WebSockets client, such as
masking of sent frames.

WebSockets expects to be used with HttpServer to provide the HttpServer
for accepting the HTTP request that begins the opening handshake. WebSockets
implements a subtype of the WebSocketInterface from HttpServer; this means
that you can create a WebSocketsHandler and pass it into the constructor for
an http server.

    Future improvements:
1. Logging of refused requests and closures due to bad behavior of client.
2. Better error handling (should we always be using "error"?)
3. Unit tests with an actual client -- to automatically test the examples.
4. Send close messages with status codes.
5. Allow users to receive control messages if they want to.
"""
module WebSockets

using HttpCommon
using HttpServer
using Codecs
using MbedTLS
using Compat; import Compat.String

export WebSocket,
       WebSocketHandler,
       write,
       read,
       close,
       send_ping,
       send_pong

const TCPSock = Base.TCPSocket

@enum ReadyState CONNECTED=0x1 CLOSING=0x2 CLOSED=0x3

""" Buffer writes to socket till flush (sock)"""
init_socket(sock) = Base.buffer_writes(sock) 


type WebSocketClosedError <: Exception end
Base.showerror(io::IO, e::WebSocketClosedError) = print(io, "Error: client disconnected")

"""
A WebSocket is a wrapper over a TcpSocket. It takes care of wrapping outgoing
data in a frame and unwrapping (and concatenating) incoming data.
"""
type WebSocket
    id::Int
    socket::TCPSock
    state::ReadyState

    function WebSocket(id::Int,socket::TCPSock)
        init_socket(socket)
        new(id, socket, CONNECTED)
    end
end

# WebSocket Frames
#
#      0                   1                   2                   3
#      0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
#     +-+-+-+-+-------+-+-------------+-------------------------------+
#     |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
#     |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
#     |N|V|V|V|       |S|             |   (if payload len==126/127)   |
#     | |1|2|3|       |K|             |                               |
#     +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
#     |     Extended payload length continued, if payload len == 127  |
#     + - - - - - - - - - - - - - - - +-------------------------------+
#     |                               |Masking-key, if MASK set to 1  |
#     +-------------------------------+-------------------------------+
#     | Masking-key (continued)       |          Payload Data         |
#     +-------------------------------- - - - - - - - - - - - - - - - +
#     :                     Payload Data continued ...                :
#     + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
#     |                     Payload Data continued ...                |
#     +---------------------------------------------------------------+
#


# Opcode values
""" *  %x0 denotes a continuation frame"""
const OPCODE_CONTINUATION = 0x00
""" *  %x1 denotes a text frame"""
const OPCODE_TEXT = 0x1
""" *  %x2 denotes a binary frame"""
const OPCODE_BINARY = 0x2
#  *  %x3-7 are reserved for further non-control frames
#
""" *  %x8 denotes a connection close"""
const OPCODE_CLOSE = 0x8
""" *  %x9 denotes a ping"""
const OPCODE_PING = 0x9
""" *  %xA denotes a pong"""
const OPCODE_PONG = 0xA
# *  %xB-F are reserved for further control frames


"""
Handshakes with subprotocols are rejected by default.
Add to supported SUBProtocols through e.g.
# Examples
```
   WebSockets.addsubproto("special-protocol")
   WebSockets.addsubproto("json")
```   
In the general websocket handler function, specialize 
further by checking 
# Example
```
if get(wsrequest.headers, "Sec-WebSocket-Protocol", "") = "special-protocol"
    specialhandler(websocket)
else
    generalhandler(websocket)
end
```
"""
const SUBProtocols= Array{String,1}() 

"Used in handshake. See SUBProtocols"
hasprotocol(s::String) = in(s,SUBProtocols)

"Used to specify handshake response. See SUBProtocols"
function addsubproto(name)
    push!(SUBProtocols, string(name))
    return true
end
""" 
    write_fragment(io, islast, data::Array{UInt8}, opcode)
Write the raw frame to a bufffer
"""
function write_fragment(io::IO, islast::Bool, data::Array{UInt8}, opcode)
    l = length(data)
    b1::UInt8 = (islast ? 0b1000_0000 : 0b0000_0000) | opcode

    # TODO: Do the mask xor thing??
    # 1. set bit 8 to 1,
    # 2. set a mask
    # 3. xor data with mask

    if l <= 125
        write(io, b1)
        write(io, @compat UInt8(l))
        write(io, data)
    elseif l <= typemax(UInt16)
        write(io, b1)
        write(io, @compat UInt8(126))
        write(io, hton(@compat UInt16(l)))
        write(io, data)
    elseif l <= typemax(UInt64)
        write(io, b1)
        write(io, @compat UInt8(127))
        write(io, hton(@compat UInt64(l)))
        write(io, data)
    else
        error("Attempted to send too much data for one websocket fragment\n")
    end
end

""" 
    write_fragment(io, islast, data::String, opcode)
A version of send_fragment for text data.
"""
function write_fragment(io::IO, islast::Bool, data::String, opcode)
    write_fragment(io, islast, data.data, opcode)
end

""" Write without interruptions"""
function locked_write(io::IO, islast::Bool, data, opcode)
    isa(io, TCPSock) && lock(io.lock)
    try
        write_fragment(io, islast, Vector{UInt8}(data), opcode)
    finally
        if isa(io, TCPSock)
            flush(io)
            unlock(io.lock)
        end
    end
end

""" Write text data; will be sent as one frame."""
function Base.write(ws::WebSocket,data::String)
    if !isopen(ws)
        @show ws
        error("Attempted write to closed WebSocket\n")
    end
    locked_write(ws.socket, true, data, OPCODE_TEXT)
end

""" Write binary data; will be sent as one frame."""
function Base.write(ws::WebSocket, data::Array{UInt8})
    if !isopen(ws)
        @show ws
        error("attempt to write to closed WebSocket\n")
    end
    locked_write(ws.socket, true, data, OPCODE_BINARY)
end


function write_ping(io::IO, data = "")
    locked_write(io, true, data, OPCODE_PING)
end
""" Send a ping message, optionally with data."""
send_ping(ws, data...) = write_ping(ws.socket, data...)


function write_pong(io::IO, data = "")
    locked_write(io, true, data, OPCODE_PONG)
end
""" Send a pong message, optionally with data."""
send_pong(ws, data...) = write_pong(ws.socket, data...)

""" 
    close(ws::WebSocket)
Send a close message.
"""
function Base.close(ws::WebSocket)
    if !isopen(ws)
        error("Attempt to close closed WebSocket")
    end

    # Ask client to acknowledge closing the connection
    locked_write(ws.socket, true, "", OPCODE_CLOSE)
    ws.state = CLOSING

    # Wait till the client responds with an OPCODE_CLOSE. This process is
    # complicated by potential blocking reads on the WebSocket in other Tasks
    # which may receive the response control frame. Synchronization of who is
    # responsible for closing the underlying socket is done using the
    # WebSocket's state. When this side initiates closing the connection it is
    # responsible for cleaning up, when the other side initiates the close the
    # read method is
    #
    # The exception handling is necessary as read_frame will error when the
    # OPCODE_CLOSE control frame is received by a potentially blocking read in
    # another Task
    try
        while ws.state === CLOSING
            wsf = read_frame(ws.socket)
            # ALERT: stuff might get lost in ether here
            if is_control_frame(wsf) && (wsf.opcode == OPCODE_CLOSE)
              ws.state = CLOSED
            end
        end

        close(ws.socket)
    catch exception
        !isa(exception, EOFError) && rethrow(exception)
    end
end
"""
    isopen(WebSocket)-> Bool
A WebSocket is closed if the underlying TCP socket closes, or if we send or
receive a close message.
"""
Base.isopen(ws::WebSocket) = (ws.state === CONNECTED) && isopen(ws.socket)


""" Represents one (received) message frame."""
type WebSocketFragment
    is_last::Bool
    rsv1::Bool
    rsv2::Bool
    rsv3::Bool
    opcode::UInt8  # This is actually a UInt4 value.
    is_masked::Bool
    payload_len::UInt64
    maskkey::Vector{UInt8}  # This will be 4 bytes on frames from the client.
    data::Vector{UInt8}  # For text messages, this is a String.
end

""" This constructor handles conversions from bytes to bools."""
function WebSocketFragment(
     fin::UInt8
    , rsv1::UInt8
    , rsv2::UInt8
    , rsv3::UInt8
    , opcode::UInt8
    , masked::UInt8
    , payload_len::UInt64
    , maskkey::Vector{UInt8}
    , data::Vector{UInt8})

    WebSocketFragment(
      fin != 0
    , rsv1 != 0
    , rsv2 != 0
    , rsv3 != 0
    , opcode
    , masked != 0
    , payload_len
    , maskkey
    , data)
end

""" Control frames have opcodes with the highest bit = 1."""
is_control_frame(msg::WebSocketFragment) = (msg.opcode & 0b0000_1000) > 0

""" Respond to pings, ignore pongs, respond to close."""
function handle_control_frame(ws::WebSocket,wsf::WebSocketFragment)
    if wsf.opcode == OPCODE_CLOSE
        # A close OPCODE can be received for two reasons. Either the other side
        # is initiating a disconnection, or the this side is (through a call to
        # close on the WebSocket) and the client has replied that it is okay
        # with closing the connection. This can be derived from the current
        # state of the WebSocket
        if ws.state !== CLOSING
            # The other side initiated the disconnect, so the action must be
            # acknowledged by replying with an empty CLOSE frame and cleaning
            # up
            try
                locked_write(ws.socket, true, "", OPCODE_CLOSE)
            catch exception
              # On sudden disconnects, the other side may be gone before the
              # close acknowledgement can be sent. This will cause an
              # ArgumentError to be thrown due to the underlying stream being
              # closed. These are swallowed here and will be replaced by a
              # WebSocketClosedError below
              !isa(exception, ArgumentError) && rethrow(exception)
            end

            close(ws.socket)
        end

        # In the other case the close method is expected to clean-up, which can
        # be triggered by changing the state of the WebSocket
        ws.state = CLOSED

        throw(WebSocketClosedError())
    elseif wsf.opcode == OPCODE_PING
        write_pong(ws.socket,wsf.data)
    elseif wsf.opcode == OPCODE_PONG
        # Nothing to do here; no reply is needed for a pong message.
    else  # %xB-F are reserved for further control frames
        error("Unknown opcode $(wsf.opcode)")
    end
end

""" Read a frame: turn bytes from the websocket into a WebSocketFragment."""
function read_frame(io::IO)
    a = read(io,UInt8)
    fin    = a & 0b1000_0000 >>> 7  # If fin, then is final fragment
    rsv1   = a & 0b0100_0000  # If not 0, fail.
    rsv2   = a & 0b0010_0000  # If not 0, fail.
    rsv3   = a & 0b0001_0000  # If not 0, fail.
    opcode = a & 0b0000_1111  # If not known code, fail.
    # TODO: add validation somewhere to ensure rsv, opcode, mask, etc are valid.

    b = read(io,UInt8)
    mask = b & 0b1000_0000 >>> 7  # If not 1, fail.

    if mask != 1
    error("WebSocket reader cannot handle incoming messages without mask. " *
        "See http://tools.ietf.org/html/rfc6455#section-5.3")
    end

    payload_len::UInt64 = b & 0b0111_1111
    if payload_len == 126
        payload_len = ntoh(read(io,UInt16))  # 2 bytes
    elseif payload_len == 127
        payload_len = ntoh(read(io,UInt64))  # 8 bytes
    end

    maskkey = Array{UInt8,1}(4)
    for i in 1:4
        maskkey[i] = read(io,UInt8)
    end

    data = Array{UInt8,1}(payload_len)
    for i in 1:payload_len
        d = read(io, UInt8)
        d = xor(d , maskkey[mod(i - 1, 4) + 1])
        data[i] = d
    end

    return WebSocketFragment(fin,rsv1,rsv2,rsv3,opcode,mask,payload_len,maskkey,data)
end
"""
    read(ws::WebSocket)
Read one non-control message from a WebSocket. Any control messages that are
read will be handled by the handle_control_frame function. This function will
not return until a full non-control message has been read. If the other side
doesn't ever complete its message, this function will never return. Only the
data (contents/body/payload) of the message will be returned from this
function.
"""
function Base.read(ws::WebSocket)
    if !isopen(ws)
        error("Attempt to read from closed WebSocket")
    end
    frame = read_frame(ws.socket)

    # Handle control (non-data) messages.
    if is_control_frame(frame)
        # Don't return control frames; they're not interesting to users.
        handle_control_frame(ws,frame)

        # Recurse to return the next data frame.
        return read(ws)
    end

    # Handle data message that uses multiple fragments.
    if !frame.is_last
        return vcat(frame.data, read(ws))
    end

    return frame.data
end

"""
    WebSocket Handshake Procedure
`generate_websocket_key(key)` transforms a websocket client key into the server's accept
value. This is done in three steps:
1. Concatenate key with magic string from RFC.
2. SHA1 hash the resulting base64 string.
3. Encode the resulting number in base64.
This function then returns the string of the base64-encoded value.
"""
function generate_websocket_key(key)
    hashed_key = digest(MD_SHA1, key*"258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    String(encode(Base64, hashed_key))
end

"""
Responds to a WebSocket handshake request.
Checks for required headers and subprotocols; sends Response(400) if they're missing or bad. Otherwise, transforms client key into accept value, and sends Reponse(101).
Function returns true for accepted handshakes.
"""
function websocket_handshake(request,client)
    if !haskey(request.headers, "Sec-WebSocket-Key")
        Base.write(client.sock, Response(400))
        return false
    end
    if get(request.headers, "Sec-WebSocket-Version", "13") != "13"
        response = Response(400)
        response.headers["Sec-WebSocket-Version"] = "13"
        Base.write(client.sock, response)
        return false
    end

    key = request.headers["Sec-WebSocket-Key"]
    if length(decode(Base64,key)) != 16 # Key must be 16 bytes
        Base.write(client.sock, Response(400))
        return false
    end
  resp_key = generate_websocket_key(key)

  response = Response(101)
  response.headers["Upgrade"] = "websocket"
  response.headers["Connection"] = "Upgrade"
  response.headers["Sec-WebSocket-Accept"] = resp_key
 
  if haskey(request.headers, "Sec-WebSocket-Protocol") 
      if hasprotocol(request.headers["Sec-WebSocket-Protocol"])
          response.headers["Sec-WebSocket-Protocol"] =  request.headers["Sec-WebSocket-Protocol"]
      else
          Base.write(client.sock, Response(400))
          return false
      end
  end 
  
  Base.write(client.sock, response)
  return true
end

""" Implement the WebSocketInterface, for compatilibility with HttpServer."""
immutable WebSocketHandler <: HttpServer.WebSocketInterface
    handle::Function
end

import HttpServer: handle, is_websocket_handshake
"""
Performs handshake. If successfull, establishes WebSocket type and calls
handler with the WebSocket and the original request. On exit from handler, closes websocket. No return value.
"""
function handle(handler::WebSocketHandler, req::Request, client::HttpServer.Client)
    websocket_handshake(req, client) || return
    sock = WebSocket(client.id, client.sock)
    handler.handle(req, sock)
    if isopen(sock) 
        try
        close(sock)
        end
    end
end
function is_websocket_handshake(handler::WebSocketHandler, req::Request)
    is_get = req.method == "GET"
    # "upgrade" for Chrome and "keep-alive, upgrade" for Firefox.
    is_upgrade = contains(lowercase(get(req.headers, "Connection", "")),"upgrade")
    is_websockets = lowercase(get(req.headers, "Upgrade", "")) == "websocket"
    return is_get && is_upgrade && is_websockets
end

end # module WebSockets
