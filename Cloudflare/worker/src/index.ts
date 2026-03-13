export interface Env {
  RELAY: DurableObjectNamespace;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const token = url.searchParams.get('token');

    if (!token || token.length < 4) {
      return new Response('Missing or invalid token', { status: 400 });
    }

    const role = url.pathname === '/host' ? 'host'
               : url.pathname === '/client' ? 'client'
               : null;

    if (!role) {
      return new Response('Use /host or /client path', { status: 404 });
    }

    if (request.headers.get('Upgrade') !== 'websocket') {
      return new Response('WebSocket required', { status: 426 });
    }

    const id = env.RELAY.idFromName(token);
    const stub = env.RELAY.get(id);
    return stub.fetch(request);
  }
};

export class AirDeskRelay implements DurableObject {
  private host: WebSocket | null = null;
  private client: WebSocket | null = null;
  private state: DurableObjectState;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const role = url.pathname === '/host' ? 'host' : 'client';

    const [clientSocket, serverSocket] = Object.values(new WebSocketPair()) as [WebSocket, WebSocket];

    this.state.acceptWebSocket(serverSocket);

    if (role === 'host') {
      this.host = serverSocket;
      (serverSocket as any).__role = 'host';
    } else {
      this.client = serverSocket;
      (serverSocket as any).__role = 'client';
    }

    return new Response(null, { status: 101, webSocket: clientSocket });
  }

  async webSocketMessage(ws: WebSocket, message: ArrayBuffer | string): Promise<void> {
    const role = (ws as any).__role;
    const peer = role === 'host' ? this.client : this.host;

    if (peer && peer.readyState === WebSocket.READY_STATE_OPEN) {
      peer.send(message);
    }
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    const role = (ws as any).__role;
    const peer = role === 'host' ? this.client : this.host;

    if (peer) {
      try { peer.close(code, reason); } catch {}
    }

    if (role === 'host') this.host = null;
    else this.client = null;
  }

  async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    await this.webSocketClose(ws, 1011, 'Error');
  }
}
