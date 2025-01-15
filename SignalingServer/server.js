const express = require('express');
const { createServer } = require('http');
const { Server } = require('socket.io');
const cors = require('cors');
const rateLimit = require('express-rate-limit');

// Server setup
const app = express();
app.use(cors()); // Allow all origins in dev

// Configure rate limiter
const limiter = rateLimit({
  windowMs: 60 * 1000, // 1 minute
  max: 100 // Limit each IP to 100 requests per windowMs
});

// Apply rate limiter to all requests
app.use(limiter);

const httpServer = createServer(app);
const io = new Server(httpServer, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"]
  }
});

// Store room and client state
const rooms = new Map();

// Configurable maximum room size
const MAX_ROOM_SIZE = process.env.MAX_ROOM_SIZE || 2;

// Logging helper
const log = (event, data) => {
  console.log(`[${new Date().toISOString()}] ${event}:`, data);
};

// --------------------------------------------------
// Signaling Protocol Definition (JSON Message Format)
// --------------------------------------------------
/*
  Message types:

  join-room: Client -> Server
  {
    "type": "join-room",
    "roomId": "yourRoomId",
    "userId": "uniqueUserId" // (Optional, but recommended for later)
  }

  peer-joined: Server -> Client
  {
    "type": "peer-joined",
    "peerId": "newlyJoinedPeerId"
  }

  peer-left: Server -> Client
  {
    "type": "peer-left",
    "peerId": "leavingPeerId"
  }

  offer: Client -> Server -> Client
  {
    "type": "offer",
    "target": "targetPeerId", // Who the offer is for
    "sender": "senderPeerId",
    "sdp": {
      "type": "offer",
      "sdp": "m=audio 9 UDP/TLS/RTP/SAVPF..."
    }
  }

  answer: Client -> Server -> Client
  {
    "type": "answer",
    "target": "targetPeerId",
    "sender": "senderPeerId",
    "sdp": {
      "type": "answer",
      "sdp": "m=audio 9 UDP/TLS/RTP/SAVPF..."
    }
  }

  ice-candidate: Client -> Server -> Client
  {
    "type": "ice-candidate",
    "target": "targetPeerId",
    "sender": "senderPeerId",
    "candidate": {
      "candidate": "candidate:4 1 UDP 1234...",
      "sdpMid": "audio",
      "sdpMLineIndex": 0
    }
  }

  error: Server -> Client
  {
    "type": "error",
    "code": "ROOM_FULL", // Or "INVALID_ROOM", "JOIN_FAILED", etc.
    "message": "Room is full"
  }

  heartbeat: Server -> Client
  {
    "type": "heartbeat"
  }
*/

// Start heartbeat mechanism
setInterval(() => {
  io.emit('heartbeat');
}, 20000);

// Socket event handlers
io.on('connection', (socket) => {
  log('connection', `Client connected: ${socket.id}`);

  // Handle room joining
  socket.on('join-room', (data) => {
    try {
      // Check if data contains roomId
      if (!data || !data.roomId) {
        log('error', `Join attempt failed - Invalid room ID from client ${socket.id}`);
        socket.emit('error', {
          type: 'INVALID_ROOM',
          message: 'Invalid room ID'
        });
        return;
      }

      const roomId = data.roomId;
      const clientsInRoom = rooms.has(roomId) ? rooms.get(roomId).size : 0;

      log('join-attempt', `Client ${socket.id} attempting to join room ${roomId} (Current occupancy: ${clientsInRoom}/${MAX_ROOM_SIZE})`);

      if (clientsInRoom >= MAX_ROOM_SIZE) {
        log('room-full', `Room ${roomId} is full. Denying access to client ${socket.id}`);
        socket.emit('error', {
          type: 'ROOM_FULL',
          message: `Room ${roomId} is full`
        });
        return;
      }

      socket.join(roomId);

      // Track room members and their socket IDs
      if (!rooms.has(roomId)) {
        log('room-create', `Creating new room ${roomId}`);
        rooms.set(roomId, new Set());
      }
      const currentRoom = rooms.get(roomId);

      // Get list of existing peers before adding the new one
      const existingPeers = Array.from(currentRoom);

      // Add the new peer
      currentRoom.add(socket.id);

      log('join-success', {
        roomId: roomId,
        clientId: socket.id,
        newRoomSize: currentRoom.size,
        existingPeers: existingPeers
      });

      // Send confirmation to joining client with list of existing peers
      socket.emit('room-joined', {
        roomId: roomId,
        clientId: socket.id,
        peers: existingPeers
      });

      // Notify others in the room about the new peer
      log('peer-join', `Emitting peer-joined to room ${roomId} with new peer ${socket.id}`);
      socket.to(roomId).emit('peer-joined', {
        peerId: socket.id
      });

    } catch (error) {
      log('error', `Join room failed for client ${socket.id}: ${error.message}`);
      socket.emit('error', {
        type: 'JOIN_ERROR',
        message: error.message
      });
    }
  });

  // Handle WebRTC signaling
  socket.on('offer', (data) => {
    try {
      if (!data?.target || !data?.sdp?.sdp || !data?.sdp?.type) {
        socket.emit('error', {
          type: 'SIGNALING_ERROR',
          message: 'Invalid offer format'
        });
        return;
      }

      // Find the room that contains the sender
      let senderRoom = null;
      for (const [roomId, clients] of rooms.entries()) {
        if (clients.has(socket.id)) {
          senderRoom = roomId;
          break;
        }
      }

      // Verify target is in the same room
      if (!senderRoom || !rooms.get(senderRoom).has(data.target)) {
        socket.emit('error', {
          type: 'INVALID_TARGET',
          message: 'Target peer is not in the same room'
        });
        return;
      }

      log('offer', {
        from: socket.id,
        to: data.target,
        sdpType: data.sdp.type,
        sdpLength: data.sdp.sdp.length,
        timestamp: new Date().toISOString()
      });

      console.log('\n=== OFFER DETAILS ===');
      console.log('From:', socket.id);
      console.log('To:', data.target);
      console.log('SDP Type:', data.sdp.type);
      console.log('SDP Content:', data.sdp.sdp);
      console.log('==================\n');

      console.log('Relaying offer to target:', data.target);

      socket.to(data.target).emit('offer', {
        type: 'offer',
        sdp: data.sdp,
        sender: socket.id
      });
    } catch (error) {
      log('error', `Offer failed: ${error.message}`);
      socket.emit('error', {
        type: 'SIGNALING_ERROR',
        message: 'Failed to process offer'
      });
    }
  });

  socket.on('answer', (data) => {
    try {
      if (!data?.target || !data?.sdp?.sdp || !data?.sdp?.type) {
        socket.emit('error', {
          type: 'SIGNALING_ERROR',
          message: 'Invalid answer format'
        });
        return;
      }

      // Find the room that contains the sender
      let senderRoom = null;
      for (const [roomId, clients] of rooms.entries()) {
        if (clients.has(socket.id)) {
          senderRoom = roomId;
          break;
        }
      }

      // Verify target is in the same room
      if (!senderRoom || !rooms.get(senderRoom).has(data.target)) {
        socket.emit('error', {
          type: 'INVALID_TARGET',
          message: 'Target peer is not in the same room'
        });
        return;
      }

      log('answer', {
        from: socket.id,
        to: data.target,
        sdpType: data.sdp.type,
        sdpLength: data.sdp.sdp.length,
        timestamp: new Date().toISOString()
      });

      console.log('\n=== ANSWER DETAILS ===');
      console.log('From:', socket.id);
      console.log('To:', data.target);
      console.log('SDP Type:', data.sdp.type);
      console.log('SDP Content:', data.sdp.sdp);
      console.log('==================\n');

      console.log('Relaying answer to target:', data.target);

      socket.to(data.target).emit('answer', {
        type: 'answer',
        sdp: data.sdp,
        sender: socket.id
      });
    } catch (error) {
      log('error', `Answer failed: ${error.message}`);
      socket.emit('error', {
        type: 'SIGNALING_ERROR',
        message: 'Failed to process answer'
      });
    }
  });

  socket.on('ice-candidate', (data) => {
    try {
      if (!data?.target || !data?.candidate?.candidate) {
        socket.emit('error', {
          type: 'SIGNALING_ERROR',
          message: 'Invalid ICE candidate format'
        });
        return;
      }

      // Find the room that contains the sender
      let senderRoom = null;
      for (const [roomId, clients] of rooms.entries()) {
        if (clients.has(socket.id)) {
          senderRoom = roomId;
          break;
        }
      }

      // Verify target is in the same room
      if (!senderRoom || !rooms.get(senderRoom).has(data.target)) {
        socket.emit('error', {
          type: 'INVALID_TARGET',
          message: 'Target peer is not in the same room'
        });
        return;
      }

      log('ice-candidate', {
        from: socket.id,
        to: data.target,
        candidateType: data.candidate.candidate.split(' ')[7],
        timestamp: new Date().toISOString()
      });

      console.log('\n=== ICE CANDIDATE DETAILS ===');
      console.log('From:', socket.id);
      console.log('To:', data.target);
      console.log('Candidate:', data.candidate.candidate);
      console.log('SDPMid:', data.candidate.sdpMid);
      console.log('SDPMLineIndex:', data.candidate.sdpMLineIndex);
      console.log('=========================\n');

      socket.to(data.target).emit('ice-candidate', {
        candidate: data.candidate,
        sender: socket.id
      });
    } catch (error) {
      log('error', `ICE candidate failed: ${error.message}`);
      socket.emit('error', {
        type: 'SIGNALING_ERROR',
        message: 'Failed to process ICE candidate'
      });
    }
  });

  // Handle disconnection
  socket.on('disconnect', () => {
    log('disconnect', `Client disconnected: ${socket.id}`);

    // Find all rooms this socket was in
    rooms.forEach((clients, roomId) => {
      if (clients.has(socket.id)) {
        clients.delete(socket.id);

        // Notify others in each room
        log('peer-left', `Emitting peer-left to room ${roomId} with peer ${socket.id}`)
        socket.to(roomId).emit('peer-left', {
          peerId: socket.id
        });

        // Clean up empty rooms
        if (clients.size === 0) {
          rooms.delete(roomId);
        }
      }
    });
  });
});

// Start server
const PORT = process.env.PORT || 3000;
httpServer.listen(PORT, '0.0.0.0', () => {
  console.log(`Server running on port ${PORT}`);
});

// Basic test endpoint
app.get('/test', (req, res) => {
  res.json({ status: 'ok' });
});