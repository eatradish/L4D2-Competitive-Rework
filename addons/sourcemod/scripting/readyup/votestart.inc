#if defined _readyup_votestart_included
 #endinput
#endif
#define _readyup_votestart_included

// ========================
//  Start Vote
// ========================
// Players may vote to go live while the teams are not full.
// The vote passes when more than half of the eligible players agree.

#define START_VOTE_TIME		20	// Seconds the vote stays on the screen
#define START_VOTE_DELAY	2.0	// Seconds to wait before the countdown starts, so the result gets seen

static int
	s_iStartVoteCaller;

bool IsTeamsFull()
{
	return GetTeamHumanCount(L4D2Team_Survivor) >= survivor_limit.IntValue
		&& GetTeamHumanCount(L4D2Team_Infected) >= z_max_player_zombies.IntValue;
}

Action StartVote_Cmd(int client, int args)
{
	if (!l4d_ready_startvote.BoolValue || !client || IsFakeClient(client))
		return Plugin_Handled;
	
	if (!inReadyUp || inLiveCountdown || readyUpMode == ReadyMode_AutoStart)
	{
		CPrintToChat(client, "%t", "StartVoteUnavailable");
		return Plugin_Handled;
	}
	
	if (!IsPlayer(client))
	{
		CPrintToChat(client, "%t", "StartVoteSpectator");
		return Plugin_Handled;
	}
	
	if (IsTeamsFull())
	{
		CPrintToChat(client, "%t", "StartVoteTeamsFull");
		return Plugin_Handled;
	}
	
	if (IsBuiltinVoteInProgress())
	{
		CPrintToChat(client, "%t", "VoteInProgress");
		return Plugin_Handled;
	}
	
	if (CheckBuiltinVoteDelay() > 0)
	{
		CPrintToChat(client, "%t", "VoteDelay", CheckBuiltinVoteDelay());
		return Plugin_Handled;
	}
	
	CreateStartVote(client);
	return Plugin_Handled;
}

void CreateStartVote(int client)
{
	s_iStartVoteCaller = client;
	
	char sTitle[64];
	FormatEx(sTitle, sizeof(sTitle), "%T", "StartVoteTitle", client);
	
	Handle hVote = CreateBuiltinVote(StartVote_ActionHandler, BuiltinVoteType_Custom_YesNo, BuiltinVoteAction_Cancel | BuiltinVoteAction_VoteEnd | BuiltinVoteAction_End);
	SetBuiltinVoteArgument(hVote, sTitle);
	SetBuiltinVoteInitiator(hVote, client);
	SetBuiltinVoteResultCallback(hVote, StartVote_ResultHandler);
	
	// Spectators have no say in this
	int numPlayers = 0;
	int[] players = new int[MaxClients];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && IsPlayer(i))
		{
			players[numPlayers++] = i;
		}
	}
	
	DisplayBuiltinVote(hVote, players, numPlayers, START_VOTE_TIME);
	
	// The caller is voting yes
	FakeClientCommand(client, "Vote Yes");
}

void StartVote_ActionHandler(Handle vote, BuiltinVoteAction action, int param1, int param2)
{
	switch (action)
	{
		case BuiltinVoteAction_End:
		{
			delete vote;
		}
		case BuiltinVoteAction_Cancel:
		{
			DisplayBuiltinVoteFail(vote, view_as<BuiltinVoteFailReason>(param1));
		}
	}
}

void StartVote_ResultHandler(Handle vote, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info)
{
	// The round may have gone live or the ready-up may have ended during the vote
	if (!inReadyUp || inLiveCountdown || readyUpMode == ReadyMode_AutoStart)
	{
		DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Generic);
		return;
	}
	
	for (int i = 0; i < num_items; i++)
	{
		if (item_info[i][BUILTINVOTEINFO_ITEM_INDEX] == BUILTINVOTES_VOTE_YES)
		{
			if (item_info[i][BUILTINVOTEINFO_ITEM_VOTES] > num_clients / 2)
			{
				char sBuffer[64];
				int iLang = (s_iStartVoteCaller && IsClientInGame(s_iStartVoteCaller)) ? s_iStartVoteCaller : LANG_SERVER;
				FormatEx(sBuffer, sizeof(sBuffer), "%T", "StartVoteAccepted", iLang);
				DisplayBuiltinVotePass(vote, sBuffer);
				CreateTimer(START_VOTE_DELAY, Timer_StartVoteAccepted, _, TIMER_FLAG_NO_MAPCHANGE);
			}
			else
			{
				DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);
			}
			return;
		}
	}
	
	DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);
}

static Action Timer_StartVoteAccepted(Handle timer)
{
	// Should the players have readied up in the meantime, the countdown is already on
	if (inReadyUp && !inLiveCountdown)
	{
		InitiateLiveCountdown();
	}
	return Plugin_Stop;
}
