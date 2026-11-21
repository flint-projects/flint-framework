/// Bounded WebSocket, server-sent event and gRPC streams.
module flint.rpc;

public import flint.rpc.grpc : RpcCode, RpcStatus, StreamLimits;
public import flint.rpc.grpc_client : GrpcCall, GrpcCallOptions, beginGrpc;
public import flint.rpc.grpc_route : registerGrpc;
public import flint.rpc.proto : decodeProto, encodeProto;
public import flint.rpc.session : GrpcService, RpcHandler, RpcStream, registerSse, sendEvent, sendHeartbeat;
public import flint.rpc.sse : Sse, SseEvent, SseNotice, SseVisitor;
public import flint.rpc.sse_client : SseClientOptions, subscribeSse;
public import flint.rpc.websocket : WebSocket;
public import flint.rpc.websocket_client : WebSocketClient, WebSocketClientOptions, connectWebSocket;
public import flint.rpc.websocket_route : WebSocketHandler, WebSocketMessage, WebSocketPeer, registerWebSocket;

@safe:
