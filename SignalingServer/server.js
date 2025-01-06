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

// Start heartbeat mechanism
setInterval(() => {
  io.emit('heartbeat');
}, 20000);

// Socket event handlers
io.on('connection', (socket) => {
  log('connection', `Client connected: ${socket.id}`);

  // Handle room joining
  socket.on('join-room', (roomId) => {
    try {
      // Check room size limit
      const clientsInRoom = rooms.has(roomId) ? rooms.get(roomId).size : 0;
      if (clientsInRoom >= MAX_ROOM_SIZE) {
        socket.emit('error', {
          type: 'ROOM_FULL',
          message: `Room ${roomId} is full`
        });
        log('join-room', `Client ${socket.id} denied entry to room ${roomId} (room full)`);
        return;
      }

      socket.join(roomId);
      
      // Track room members
      if (!rooms.has(roomId)) {
        rooms.set(roomId, new Set());
      }
      rooms.get(roomId).add(socket.id);

      log('join-room', `Client ${socket.id} joined room ${roomId}`);
      
      // Notify others in room
      socket.to(roomId).emit('peer-joined', {
        peerId: socket.id
      });

    } catch (error) {
      log('error', `Join room failed: ${error.message}`);
      socket.emit('error', {
        type: 'JOIN_ERROR',
        message: error.message
      });
    }
  });

  // Handle WebRTC signaling
  socket.on('offer', (data) => {
    try {
      log('offer', `From ${socket.id} to ${data.target}`);
      socket.to(data.target).emit('offer', {
        sdp: data.sdp,
        sender: socket.id
      });
    } catch (error) {
      log('error', `Offer failed: ${error.message}`);
    }
  });

  socket.on('answer', (data) => {
    try {
      log('answer', `From ${socket.id} to ${data.target}`);
      socket.to(data.target).emit('answer', {
        sdp: data.sdp,
        sender: socket.id 
      });
    } catch (error) {
      log('error', `Answer failed: ${error.message}`);
    }
  });

  socket.on('ice-candidate', (data) => {
    try {
      log('ice-candidate', `From ${socket.id} to ${data.target}`);
      socket.to(data.target).emit('ice-candidate', {
        candidate: data.candidate,
        sender: socket.id
      });
    } catch (error) {
      log('error', `ICE candidate failed: ${error.message}`);
    }
  });

  // Handle disconnection
  socket.on('disconnect', () => {
    log('disconnect', `Client disconnected: ${socket.id}`);
    
    // Remove from all rooms
    rooms.forEach((clients, roomId) => {
      if (clients.has(socket.id)) {
        clients.delete(socket.id);
        // Notify others in room
        socket.to(roomId).emit('peer-left', {
          peerId: socket.id
        });
      }
    });
  });
});

// Start server
const PORT = process.env.PORT || 3000;
httpServer.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});

// Basic test endpoint
app.get('/test', (req, res) => {
  res.json({ status: 'ok' });
});

// Example client usage:
/*
const socket = io('http://localhost:3000');

socket.on('connect', () => {
  console.log('Connected to signaling server');
  
  // Join room
  socket.emit('join-room', 'test-room');
});

socket.on('peer-joined', (data) => {
  console.log('Peer joined:', data.peerId);
  
  // Create and send offer
  const offer = // ... create WebRTC offer
  socket.emit('offer', {
    target: data.peerId,
    sdp: offer
  });
});

socket.on('offer', (data) => {
  console.log('Received offer from:', data.sender);
  // Handle offer and create answer
});

socket.on('answer', (data) => {
  console.log('Received answer from:', data.sender);
  // Handle answer 
});

socket.on('ice-candidate', (data) => {
  console.log('Received ICE candidate from:', data.sender);
  // Handle ICE candidate
});

socket.on('error', (error) => {
  console.error('Server error:', error);
});
*/