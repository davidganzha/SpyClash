import { createClientFromRequest } from 'npm:@base44/sdk@0.8.25';

Deno.serve(async (req) => {
  try {
    const base44 = createClientFromRequest(req);
    const user = await base44.auth.me();
    
    if (!user) {
      return Response.json({ error: 'Unauthorized' }, { status: 401 });
    }

    const body = await req.json();
    const { roomId } = body;

    if (!roomId) {
      return Response.json({ error: 'Missing roomId' }, { status: 400 });
    }

    const rooms = await base44.entities.GameRoom.filter({ id: roomId });
    const gameRoom = rooms?.[0];

    if (!gameRoom) {
      return Response.json({ error: 'Room not found' }, { status: 404 });
    }

    // Check if user is in the game
    const playerInGame = gameRoom.players?.some(p => p.email === user.email);
    if (!playerInGame) {
      return Response.json({ error: 'Not a player in this room' }, { status: 403 });
    }

    const players = gameRoom.players || [];
    
    if (players.length < 2) {
      return Response.json({ error: 'Need at least 2 players' }, { status: 400 });
    }

    const currentQuestionsInRound = gameRoom.questions_in_round || 0;
    const nextQuestionsInRound = currentQuestionsInRound + 1;
    
    // Find current asker and answerer indices
    const currentAnswererIndex = players.findIndex(p => p.email === gameRoom.current_answerer_email);
    
    // Next asker is the current answerer
    const nextAskerIndex = currentAnswererIndex;
    
    // Next answerer is the next player in rotation
    let nextAnswererIndex = (currentAnswererIndex + 1) % players.length;
    
    // Make sure next answerer is not the new asker
    if (nextAnswererIndex === nextAskerIndex) {
      nextAnswererIndex = (nextAnswererIndex + 1) % players.length;
    }
    
    const updateData = {
      current_asker_email: players[nextAskerIndex].email,
      current_answerer_email: players[nextAnswererIndex].email,
      questions_in_round: nextQuestionsInRound
    };
    
    // If 4 questions already asked, also increment round number
    if (nextQuestionsInRound >= 4) {
      updateData.round_number = (gameRoom.round_number || 1) + 1;
      updateData.questions_in_round = 0;
    }
    
    await base44.entities.GameRoom.update(roomId, updateData);

    return Response.json({ success: true });
  } catch (error) {
    console.error('advanceRound error:', error.message);
    return Response.json({ error: error.message }, { status: 500 });
  }
});