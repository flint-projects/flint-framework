/// Bounded WebSocket, server-sent event and gRPC streams.
module flint.engine.rpc;

public import flint.engine.rpc.grpc : RpcCode, RpcStatus, StreamLimits;
public import flint.engine.rpc.grpc_client : GrpcCall, GrpcCallOptions, beginGrpc;
public import flint.engine.rpc.grpc_route : registerGrpc;
public import flint.engine.rpc.proto : decodeProto, encodeProto;
public import flint.engine.rpc.session : GrpcService, RpcHandler, RpcStream, registerSse, sendEvent, sendHeartbeat;
public import flint.engine.rpc.sse : Sse, SseEvent, SseNotice, SseVisitor;
public import flint.engine.rpc.sse_client : SseClientOptions, subscribeSse;
public import flint.engine.rpc.websocket : WebSocket;
public import flint.engine.rpc.websocket_client : WebSocketClient, WebSocketClientOptions, connectWebSocket;
public import flint.engine.rpc.websocket_route : WebSocketHandler, WebSocketMessage, WebSocketPeer, registerWebSocket;

@safe:
