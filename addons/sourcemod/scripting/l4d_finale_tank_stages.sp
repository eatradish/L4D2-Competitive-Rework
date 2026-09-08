#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

#define PLUGIN_VERSION "1.0.0"
#define MAP_NAME_MAX_LENGTH 64

// Finale stage types (same enum eq_finale_tanks uses)
#define FINALE_CUSTOM_TANK          8
#define FINALE_GAUNTLET_BOSS        16
#define FINALE_GAUNTLET_ESCAPE      17

public Plugin myinfo =
{
	name = "[L4D2] Finale Tank Stage Restore",
	author = "L4D2-Comp-Source",
	description = "Re-allows the vanilla finale tank stages that eq_finale_tanks suppresses, up to a configured count.",
	version = PLUGIN_VERSION,
	url = ""
};

// Map -> how many finale tank stages to allow in total (vanilla scripts define
// the stage sequence; eq_finale_tanks normally lets only one through).
StringMap g_hMaxTanks;

int g_iRestored = 0;
bool g_bSpawnPending = false;

public void OnPluginStart()
{
	g_hMaxTanks = new StringMap();

	RegServerCmd("tank_map_finale_tank_stages", Cmd_SetMaxTanks,
		"tank_map_finale_tank_stages <mapname> <count> - allow <count> finale tank stages (eq_finale_tanks otherwise allows 1)");
}

public void OnMapStart()
{
	g_iRestored = 0;
	g_bSpawnPending = false;
}

Action Cmd_SetMaxTanks(int args)
{
	if (args != 2)
	{
		PrintToServer("Usage: tank_map_finale_tank_stages <mapname> <count>");
		LogError("Usage: tank_map_finale_tank_stages <mapname> <count>");
		return Plugin_Handled;
	}

	char mapname[MAP_NAME_MAX_LENGTH];
	GetCmdArg(1, mapname, sizeof(mapname));

	char countBuf[8];
	GetCmdArg(2, countBuf, sizeof(countBuf));
	int count = StringToInt(countBuf);

	if (count <= 1)
	{
		// 1 = eq_finale_tanks' own behaviour, nothing to restore.
		g_hMaxTanks.Remove(mapname);
	}
	else
	{
		g_hMaxTanks.SetValue(mapname, count);
	}

	return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// The vanilla finale scripts already define a sequence of TANK stages (e.g.
// c1m4_atrium_finale.nut: stages 6, 14 and 22), and the engine fires them
// regardless of whether the previous tank is still alive. eq_finale_tanks
// suppresses every stage except one, which is what limits maps to a single
// finale tank.
//
// left4dhooks exposes L4D2_OnChangeFinaleStage_PostHandled, which only fires
// when a pre-hook returned Plugin_Handled - i.e. exactly when eq_finale_tanks
// suppressed a stage. We count those suppressions and re-spawn the tank for the
// ones the map is configured to allow.
// ---------------------------------------------------------------------------

public void L4D2_OnChangeFinaleStage_PostHandled(int finaleType, const char[] arg)
{
	if (finaleType != FINALE_CUSTOM_TANK
		&& finaleType != FINALE_GAUNTLET_BOSS
		&& finaleType != FINALE_GAUNTLET_ESCAPE)
	{
		return;
	}

	char mapname[MAP_NAME_MAX_LENGTH];
	GetCurrentMap(mapname, sizeof(mapname));

	int maxTanks = 0;
	if (!g_hMaxTanks.GetValue(mapname, maxTanks) || maxTanks <= 1)
	{
		return;
	}

	// eq_finale_tanks already let one tank through, so we only need to restore
	// (maxTanks - 1) of the suppressed stages, starting with the first one.
	if (g_iRestored >= (maxTanks - 1) || g_bSpawnPending)
	{
		return;
	}

	g_iRestored++;
	g_bSpawnPending = true;
	CreateTimer(1.0, Timer_SpawnTank, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_SpawnTank(Handle timer)
{
	g_bSpawnPending = false;

	char mapname[MAP_NAME_MAX_LENGTH];
	GetCurrentMap(mapname, sizeof(mapname));

	// A tank is usually already waiting in the director's queue when a TANK
	// stage begins; asking for one explicitly keeps the stage's own spawn
	// timing instead of inventing a position.
	float vPos[3];
	float vAng[3];

	int survivor = GetAnySurvivor();
	if (survivor > 0 && L4D_GetRandomPZSpawnPosition(survivor, 8, 20, vPos))
	{
		int tank = L4D2_SpawnTank(vPos, vAng);

		if (tank <= 0)
		{
			LogError("[FinaleTankStages] L4D2_SpawnTank failed on %s at %.1f %.1f %.1f",
				mapname, vPos[0], vPos[1], vPos[2]);
		}
	}
	else
	{
		// Fallback: let the director spawn it the normal way.
		L4D2Direct_SetVSTankToSpawnThisRound(GameRules_GetProp("m_bInSecondHalfOfRound"), true);
	}

	return Plugin_Stop;
}

int GetAnySurvivor()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
		{
			return i;
		}
	}
	return 0;
}
