#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <adminmenu>

#define PLUGIN_VERSION "1.0.0"
#define CVAR_FLAGS     FCVAR_NOTIFY

// L4D2 team ids
#define TEAM_SPECTATOR 1
#define TEAM_SURVIVOR  2
#define TEAM_INFECTED  3

public Plugin myinfo =
{
	name = "[L4D2] Team Menu",
	author = "L4D2-Comp-Source",
	description = "Admin menu item to move a player to spectators/survivors/infected.",
	version = PLUGIN_VERSION,
	url = ""
};

ConVar g_cvAddTopMenu;
TopMenuObject g_hAdminItem = INVALID_TOPMENUOBJECT;
bool g_bMenuAdded;
int g_iSelectedTeam[MAXPLAYERS + 1];

// ---------------------------------------------------------------------------
// Why this plugin exists instead of adminmenu_custom.txt:
// adminmenu's ParamCheck() detects placeholders with StrContains(), so a
// command like "sm_swapto 2 @1" becomes "sm_swapto 2 #21" and the substring
// search for "#2" matches "#21" -> it believes another parameter is pending and
// re-opens the menu forever. A native TopMenu has no placeholder parsing at
// all, so this cannot happen.
// ---------------------------------------------------------------------------

public void OnPluginStart()
{
	LoadTranslations("common.phrases");

	RegAdminCmd("sm_teammenu", Cmd_TeamMenu, ADMFLAG_KICK, "sm_teammenu - open the team move menu");
	RegAdminCmd("sm_swapto2", Cmd_SwapTo, ADMFLAG_KICK, "sm_swapto2 <player> <1|2|3> - move a player to a team (1=spec 2=survivor 3=infected)");

	g_cvAddTopMenu = CreateConVar("l4d_team_menu_adminmenu", "1",
		"Add 'Move player to team' item in admin menu under 'Player commands'? (0 - No, 1 - Yes)",
		CVAR_FLAGS, true, 0.0, true, 1.0);
	AutoExecConfig(true, "l4d_team_menu");

	g_cvAddTopMenu.AddChangeHook(OnCvarChanged);

	if (g_cvAddTopMenu.BoolValue)
	{
		TopMenu topmenu;
		if (LibraryExists("adminmenu") && ((topmenu = GetAdminTopMenu()) != null))
		{
			OnAdminMenuReady(topmenu);
		}
	}
}

public void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (g_cvAddTopMenu.BoolValue)
	{
		TopMenu topmenu;
		if (LibraryExists("adminmenu") && ((topmenu = GetAdminTopMenu()) != null))
		{
			OnAdminMenuReady(topmenu);
		}
	}
	else
	{
		RemoveAdminItem();
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (strcmp(name, "adminmenu") == 0)
	{
		g_bMenuAdded = false;
		g_hAdminItem = INVALID_TOPMENUOBJECT;
	}
}

public void OnLibraryAdded(const char[] name)
{
	if (strcmp(name, "adminmenu") == 0)
	{
		TopMenu topmenu;
		if (g_cvAddTopMenu.BoolValue && ((topmenu = GetAdminTopMenu()) != null))
		{
			OnAdminMenuReady(topmenu);
		}
	}
}

TopMenu g_hTopMenu;

public void OnAdminMenuReady(Handle aTopMenu)
{
	AddAdminItem(aTopMenu);

	TopMenu topmenu = TopMenu.FromHandle(aTopMenu);

	// Block us from being called twice
	if (g_hTopMenu == topmenu)
	{
		return;
	}

	g_hTopMenu = topmenu;
}

void RemoveAdminItem()
{
	AddAdminItem(null, true);
}

void AddAdminItem(Handle aTopMenu, bool bRemoveItem = false)
{
	TopMenu hAdminMenu;

	if (aTopMenu != null)
	{
		hAdminMenu = TopMenu.FromHandle(aTopMenu);
	}
	else
	{
		if (!LibraryExists("adminmenu"))
		{
			return;
		}
		if (null == (hAdminMenu = GetAdminTopMenu()))
		{
			return;
		}
	}

	if (g_bMenuAdded)
	{
		if ((bRemoveItem || !g_cvAddTopMenu.BoolValue) && g_hAdminItem != INVALID_TOPMENUOBJECT)
		{
			hAdminMenu.Remove(g_hAdminItem);
			g_bMenuAdded = false;
		}
	}
	else if (g_cvAddTopMenu.BoolValue)
	{
		TopMenuObject hCategory = hAdminMenu.FindCategory(ADMINMENU_PLAYERCOMMANDS);

		if (hCategory)
		{
			g_hAdminItem = hAdminMenu.AddItem("L4D2_TeamMenu_Item", AdminMenuTeamHandler,
				hCategory, "sm_teammenu", ADMFLAG_KICK, "Move a player to another team");
			g_bMenuAdded = true;
		}
	}
}

void AdminMenuTeamHandler(Handle topmenu, TopMenuAction action, TopMenuObject object_id,
	int param, char[] buffer, int maxlength)
{
	if (action == TopMenuAction_SelectOption)
	{
		ShowPlayerMenu(param);
	}
	else if (action == TopMenuAction_DisplayOption)
	{
		FormatEx(buffer, maxlength, "移动玩家到队伍");
	}
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

Action Cmd_TeamMenu(int client, int args)
{
	if (client == 0)
	{
		PrintToServer("[TeamMenu] This command is in-game only.");
		return Plugin_Handled;
	}

	ShowPlayerMenu(client);
	return Plugin_Handled;
}

Action Cmd_SwapTo(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "[SM] Usage: sm_swapto2 <player> <1|2|3>  (1=spec 2=survivor 3=infected)");
		return Plugin_Handled;
	}

	char argBuf[MAX_NAME_LENGTH];
	GetCmdArg(1, argBuf, sizeof(argBuf));

	char teamBuf[8];
	GetCmdArg(2, teamBuf, sizeof(teamBuf));
	int team = StringToInt(teamBuf);

	if (!IsValidTeam(team))
	{
		ReplyToCommand(client, "[SM] Invalid team '%s'. Use 1 (spec), 2 (survivor) or 3 (infected).", teamBuf);
		return Plugin_Handled;
	}

	int target = FindTarget(client, argBuf, true, false);
	if (target == -1)
	{
		return Plugin_Handled;
	}

	MovePlayerToTeam(client, target, team);
	return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// Menus
// ---------------------------------------------------------------------------

void ShowPlayerMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Player, MENU_ACTIONS_DEFAULT);
	menu.SetTitle("选择要移动的玩家");

	char sInfo[16];
	char sName[MAX_NAME_LENGTH];
	int count = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
		{
			continue;
		}

		FormatEx(sInfo, sizeof(sInfo), "%d", GetClientUserId(i));
		FormatEx(sName, sizeof(sName), "%N (队伍 %d)", i, GetClientTeam(i));
		menu.AddItem(sInfo, sName);
		count++;
	}

	if (count == 0)
	{
		delete menu;
		PrintToChat(client, "[TeamMenu] 没有可移动的玩家。");
		return;
	}

	menu.Display(client, MENU_TIME_FOREVER);
}
public int MenuHandler_Player(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char sInfo[16];
		menu.GetItem(param2, sInfo, sizeof(sInfo));

		int userid = StringToInt(sInfo);
		int target = GetClientOfUserId(userid);

		if (!target || !IsClientInGame(target))
		{
			PrintToChat(param1, "[TeamMenu] 该玩家已离开。");
			return 0;
		}

		ShowTeamMenu(param1, target);
	}

	return 0;
}

void ShowTeamMenu(int client, int target)
{
	Menu menu = new Menu(MenuHandler_Team, MENU_ACTIONS_DEFAULT);
	menu.SetTitle("把 %N 移动到：", target);

	menu.AddItem("1", "旁观");
	menu.AddItem("2", "幸存者队");
	menu.AddItem("3", "感染者队");

	g_iSelectedTeam[client] = GetClientUserId(target);
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Team(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char sInfo[8];
		menu.GetItem(param2, sInfo, sizeof(sInfo));

		int team = StringToInt(sInfo);
		int target = GetClientOfUserId(g_iSelectedTeam[param1]);

		if (!target || !IsClientInGame(target))
		{
			PrintToChat(param1, "[TeamMenu] 该玩家已离开。");
			return 0;
		}

		MovePlayerToTeam(param1, target, team);
	}

	return 0;
}

// ---------------------------------------------------------------------------
// Team move
// ---------------------------------------------------------------------------

bool IsValidTeam(int team)
{
	return (team >= TEAM_SPECTATOR && team <= TEAM_INFECTED);
}

void MovePlayerToTeam(int admin, int target, int team)
{
	if (GetClientTeam(target) == team)
	{
		ReplyToCommand(admin, "[SM] %N 已经在该队伍。", target);
		return;
	}

	// Infected -> anything: kill the SI so no ghost/ragdoll is left behind.
	if (GetClientTeam(target) == TEAM_INFECTED && team != TEAM_INFECTED)
	{
		if (IsPlayerAlive(target))
		{
			ForcePlayerSuicide(target);
		}
	}

	if (team == TEAM_SURVIVOR)
	{
		// Joining survivors in L4D2 goes through taking over a bot, otherwise the
		// client lands in the spectator queue and never spawns.
		int bot = FindSurvivorBot();

		if (bot > 0)
		{
			int flags = GetCommandFlags("sb_takecontrol");
			SetCommandFlags("sb_takecontrol", flags & ~FCVAR_CHEAT);
			FakeClientCommand(target, "sb_takecontrol");
			SetCommandFlags("sb_takecontrol", flags);
		}
		else
		{
			ChangeClientTeam(target, TEAM_SURVIVOR);
		}
	}
	else
	{
		ChangeClientTeam(target, team);
	}

	LogAction(admin, target, "\"%L\" moved \"%L\" to team %d", admin, target, team);

	char sTeam[16];
	TeamName(team, sTeam, sizeof(sTeam));
	PrintToChatAll("[SM] %N 把 %N 移动到%s。", admin, target, sTeam);
}

int FindSurvivorBot()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == TEAM_SURVIVOR)
		{
			return i;
		}
	}
	return -1;
}

void TeamName(int team, char[] buffer, int maxlen)
{
	switch (team)
	{
		case TEAM_SPECTATOR: strcopy(buffer, maxlen, "旁观");
		case TEAM_SURVIVOR:  strcopy(buffer, maxlen, "幸存者队");
		case TEAM_INFECTED:  strcopy(buffer, maxlen, "感染者队");
		default:             strcopy(buffer, maxlen, "未知队伍");
	}
}
