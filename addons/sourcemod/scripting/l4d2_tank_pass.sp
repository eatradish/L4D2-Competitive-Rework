#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <colors>
#include <builtinvotes>

#define PLUGIN_VERSION "1.0.0"

#define TEAM_INFECTED    3
#define ZOMBIECLASS_TANK 8

#define TANK_PANEL_TIME  15   // 面板展示秒数（超时/ESC = 自己玩，保留控制）

// ---------------------------------------------------------------------------
// 坦克移交（面板 + 队内投票）
//
// 流程：
//   1) 真人拿到坦克控制权时弹出面板。
//      trigger = item_pickup 事件里 item 为 "tank_claw"（引擎的"获得坦克"信号，
//      仓库里 l4d2lib/tanks.sp 也用同一信号跟踪坦克换人），另加
//      L4D_OnReplaceTank 兜底（延迟 1 秒检查，防止控制权切换还没生效）。
//      每只坦克只自动弹一次，不提供手动呼出/重开（避免拿到坦克后随时换人）。
//   2) 面板选项：
//        - "自己玩（保留坦克控制）"  -> 关掉面板，控制保留（超时/ESC 同效）
//        - 选择某个队友              -> 发起队内投票
//   3) 队内投票 = 感染者队伍里所有真人（含坦克本人与目标；发起者默认投同意）。
//      通过规则与 readyup 的开始投票一致：同意票 > 可投票人数的一半。
//   4) 通过 -> 移交控制权；未通过/取消 -> 仍由原玩家控制。
//
// 移交实现（与 raziEiL 的 l4d_tank_pass、仓库内 l4d_tank_control_eq 相同的
// 成熟做法）：目标若在操控其它特感先换成 bot（不杀死玩家）→ 拉到坦克位置 →
// L4D_ReplaceTank()（引擎 ZombieManager::ReplaceTank）→ 设置 PassedCount，
// 避免引擎多段控制判定异常。
// ---------------------------------------------------------------------------

ConVar g_cvEnable;
ConVar g_cvVoteTime;

bool g_bPanelShown;         // 当前这只坦克是否已经自动弹过面板
bool g_bInternalTransfer;   // 本插件自己发起的移交，不再触发其它逻辑

bool g_bVoteActive;
int  g_iVoteTank;           // 发起投票的坦克（client index）
int  g_iVoteTarget;         // 目标（client index）
Handle g_hVote;

public Plugin myinfo =
{
	name        = "[L4D2] Tank Pass",
	author      = "L4D2-Comp-Source",
	description = "Tank holder can pass the tank to a teammate through a team vote.",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cvEnable   = CreateConVar("sm_tankpass_enable", "1", "Enable the tank pass panel / team vote (0 = off).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvVoteTime = CreateConVar("sm_tankpass_votetime", "15", "Tank pass vote duration (seconds).", FCVAR_NOTIFY, true, 5.0, true, 60.0);
	AutoExecConfig(true, "l4d2_tank_pass");

	HookEvent("tank_spawn",         Event_TankSpawn, EventHookMode_Post);
	HookEvent("item_pickup",        Event_ItemPickup, EventHookMode_Post);
	HookEvent("player_death",       Event_PlayerDeath, EventHookMode_Post);
	HookEvent("player_team",        Event_PlayerTeam, EventHookMode_Post);
	HookEvent("player_bot_replace", Event_PlayerBotReplace, EventHookMode_Post);
	HookEvent("round_end",          Event_RoundEnd, EventHookMode_PostNoCopy);

	// 面板只在拿到坦克时自动弹一次；不提供手动命令重开（防止随时换人）。

	// 插件热载/中途加载时，如果场上已有真人坦克，也给他一次面板（便于测试）
	CreateTimer(2.0, Timer_InitialCheck, _, TIMER_FLAG_NO_MAPCHANGE);
}

// ---------------------------------------------------------------------------
// 事件 / 判定
// ---------------------------------------------------------------------------

void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
	g_bPanelShown = false;

	if (g_bVoteActive)
		CancelTankVote("新坦克已刷新");
}

void Event_ItemPickup(Event event, const char[] name, bool dontBroadcast)
{
	char sItem[32];
	event.GetString("item", sItem, sizeof(sItem));

	if (!StrEqual(sItem, "tank_claw"))
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return;

	// 坦克换人了：进行中的投票作废
	if (g_bVoteActive && client != g_iVoteTank)
		CancelTankVote("坦克控制权已变更");

	ShowPassPanel(client);
}

public void L4D_OnReplaceTank(int tank, int newtank)
{
	if (g_bInternalTransfer)
		return;

	if (newtank < 1 || newtank > MaxClients || !IsClientInGame(newtank) || IsFakeClient(newtank))
		return;

	if (g_bVoteActive && newtank != g_iVoteTank)
		CancelTankVote("坦克控制权已变更");

	// 控制权切换可能还没完全生效，延迟再检查一次
	DataPack dp = new DataPack();
	dp.WriteCell(GetClientUserId(newtank));
	CreateTimer(1.0, Timer_DelayedPanel, dp, TIMER_FLAG_NO_MAPCHANGE);
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bVoteActive)
		return;

	if (GetClientOfUserId(event.GetInt("userid")) == g_iVoteTank)
		CancelTankVote("坦克已死亡");
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bVoteActive)
		return;

	if (event.GetInt("team") == TEAM_INFECTED)
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client == g_iVoteTank || client == g_iVoteTarget)
		CancelTankVote("相关玩家已离开感染者队伍");
}

void Event_PlayerBotReplace(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bVoteActive)
		return;

	int player = GetClientOfUserId(event.GetInt("player"));
	if (player == g_iVoteTank || player == g_iVoteTarget)
		CancelTankVote("相关玩家已离开（bot 接管）");
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	g_bPanelShown = false;

	if (g_bVoteActive)
		CancelTankVote("回合结束");
}

public void OnClientDisconnect(int client)
{
	if (!g_bVoteActive)
		return;

	if (client == g_iVoteTank || client == g_iVoteTarget)
		CancelTankVote("相关玩家已离开");
}

// ---------------------------------------------------------------------------
// 面板
// ---------------------------------------------------------------------------

void ShowPassPanel(int tank)
{
	if (!g_cvEnable.BoolValue)
		return;

	if (g_bPanelShown)
		return;

	if (!IsCurrentTank(tank))
		return;

	Menu menu = new Menu(MenuHandler_Pass);
	menu.SetTitle("【坦克】自己玩，或选择队友移交（将发起队内投票）");
	menu.AddItem("self", "自己玩（保留坦克控制）");

	char sInfo[16];
	int targets = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == tank)
			continue;

		if (!IsValidVoteTarget(i))
			continue;

		char sName[MAX_NAME_LENGTH];
		FormatEx(sInfo, sizeof(sInfo), "%d", GetClientUserId(i));
		FormatEx(sName, sizeof(sName), "%N", i);
		menu.AddItem(sInfo, sName);
		targets++;
	}

	if (targets == 0)
	{
		delete menu;
		CPrintToChat(tank, "{blue}[坦克]{default} 当前没有可移交的队友，自己玩吧。");
		return;
	}

	g_bPanelShown = true;
	menu.ExitButton = true;
	menu.Display(tank, TANK_PANEL_TIME);

	CPrintToChat(tank, "{blue}[坦克]{default} 可以{olive}自己玩{default}，或选队友发起{olive}队内投票{default}移交控制权（每只坦克只会自动弹一次）。");
}

public int MenuHandler_Pass(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		delete menu;
		return 0;
	}

	if (action != MenuAction_Select)
		return 0;

	char sInfo[16];
	menu.GetItem(param2, sInfo, sizeof(sInfo));

	if (StrEqual(sInfo, "self"))
		return 0;  // 自己玩：面板关闭，控制保留

	int tank = param1;
	int target = GetClientOfUserId(StringToInt(sInfo));

	if (!IsCurrentTank(tank))
	{
		CPrintToChat(tank, "{blue}[坦克]{default} 你已不是当前坦克。");
		return 0;
	}

	if (target <= 0 || !IsValidVoteTarget(target))
	{
		CPrintToChat(tank, "{blue}[坦克]{default} 该玩家已不可选。");
		return 0;
	}

	StartTankVote(tank, target);
	return 0;
}

// ---------------------------------------------------------------------------
// 队内投票（内置投票系统；与 readyup 的开始投票同一套写法）
// ---------------------------------------------------------------------------

void StartTankVote(int tank, int target)
{
	if (g_bVoteActive)
	{
		CPrintToChat(tank, "{blue}[坦克]{default} 已有一项坦克投票进行中。");
		return;
	}

	if (IsBuiltinVoteInProgress())
	{
		CPrintToChat(tank, "{blue}[坦克]{default} 当前有其他投票进行中，请稍后再试。");
		return;
	}

	// 可投票 = 感染者队伍里所有真人（含坦克本人与目标）
	int[] players = new int[MaxClients];
	int num = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		if (GetClientTeam(i) != TEAM_INFECTED)
			continue;

		players[num++] = i;
	}

	if (num == 0)
		return;

	g_bVoteActive = true;
	g_iVoteTank = tank;
	g_iVoteTarget = target;

	int iVoteTime = g_cvVoteTime.IntValue;

	char sTitle[128];
	FormatEx(sTitle, sizeof(sTitle), "是否把坦克交给 %N？（队内投票）", target);

	g_hVote = CreateBuiltinVote(TankVote_ActionHandler, BuiltinVoteType_Custom_YesNo,
		BuiltinVoteAction_Cancel | BuiltinVoteAction_VoteEnd | BuiltinVoteAction_End);
	SetBuiltinVoteArgument(g_hVote, sTitle);
	SetBuiltinVoteInitiator(g_hVote, tank);
	SetBuiltinVoteResultCallback(g_hVote, TankVote_ResultHandler);
	DisplayBuiltinVote(g_hVote, players, num, iVoteTime);

	// 发起者默认同意
	FakeClientCommand(tank, "Vote Yes");

	AnnounceToInfected("{blue}[坦克投票]{default} {olive}%N{default} 发起：是否把坦克交给 {olive}%N{default}？（%d 秒）", tank, target, iVoteTime);
	LogMessage("[TankPass] %L 发起队内投票：把坦克交给 %L", tank, target);
}

public void TankVote_ActionHandler(Handle vote, BuiltinVoteAction action, int param1, int param2)
{
	switch (action)
	{
		case BuiltinVoteAction_End:
		{
			g_hVote = null;
			delete vote;
		}
		case BuiltinVoteAction_Cancel:
		{
			// 投票被系统取消（被其它投票顶掉、发起者断线等）
			if (g_bVoteActive)
			{
				g_bVoteActive = false;
				AnnounceToInfected("{blue}[坦克投票]{default} 投票已取消。");
				LogMessage("[TankPass] 坦克投票被系统取消 (reason %d)", param1);
			}

			DisplayBuiltinVoteFail(vote, view_as<BuiltinVoteFailReason>(param1));
		}
	}
}

public void TankVote_ResultHandler(Handle vote, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info)
{
	int yes = 0;
	int no = 0;

	for (int i = 0; i < num_items; i++)
	{
		if (item_info[i][BUILTINVOTEINFO_ITEM_INDEX] == BUILTINVOTES_VOTE_YES)
			yes = item_info[i][BUILTINVOTEINFO_ITEM_VOTES];
		else if (item_info[i][BUILTINVOTEINFO_ITEM_INDEX] == BUILTINVOTES_VOTE_NO)
			no = item_info[i][BUILTINVOTEINFO_ITEM_VOTES];
	}

	int tank = g_iVoteTank;
	int target = g_iVoteTarget;
	g_bVoteActive = false;

	// 投票期间状态可能已改变：重验
	if (!IsCurrentTank(tank))
	{
		DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Generic);
		AnnounceToInfected("{blue}[坦克投票]{default} 投票结束，但坦克控制权已变更，移交取消。");
		return;
	}

	if (!IsValidVoteTarget(target))
	{
		DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Generic);
		AnnounceToInfected("{blue}[坦克投票]{default} 目标玩家已不可用，移交取消。");
		return;
	}

	// 通过与 readyup 的开始投票同一规则：同意票 > 可投票人数的一半
	if (yes > num_clients / 2)
	{
		char sBuffer[128];
		FormatEx(sBuffer, sizeof(sBuffer), "坦克将交给 %N", target);
		DisplayBuiltinVotePass(vote, sBuffer);

		AnnounceToInfected("{blue}[坦克]{default} 投票通过（同意 %d / 反对 %d），坦克交给 {olive}%N{default}。", yes, no, target);
		TransferTank(tank, target);
		LogMessage("[TankPass] 投票通过（同意 %d / 反对 %d）：%L -> %L", yes, no, tank, target);
	}
	else
	{
		DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);
		AnnounceToInfected("{blue}[坦克]{default} 投票未通过（同意 %d / 反对 %d），坦克仍由 {olive}%N{default} 控制。", yes, no, tank);
		LogMessage("[TankPass] 投票未通过（同意 %d / 反对 %d）：保持 %L", yes, no, tank);
	}
}

void CancelTankVote(const char[] sReason)
{
	if (!g_bVoteActive)
		return;

	g_bVoteActive = false;

	if (g_hVote != null)
	{
		// 结束投票界面；Handle 在 BuiltinVoteAction_End 里删除
		DisplayBuiltinVoteFail(g_hVote, BuiltinVoteFail_Generic);
	}

	AnnounceToInfected("{blue}[坦克投票]{default} 投票已取消：%s", sReason);
	LogMessage("[TankPass] 坦克投票已取消：%s", sReason);
}

// ---------------------------------------------------------------------------
// 移交实现
// ---------------------------------------------------------------------------

void TransferTank(int tank, int target)
{
	if (!IsCurrentTank(tank) || !IsValidVoteTarget(target))
	{
		AnnounceToInfected("{blue}[坦克]{default} 移交条件已不满足，操作取消。");
		return;
	}

	// 目标正在操控其它特感：先换成 bot（不杀死玩家）
	if (IsPlayerAlive(target) && !L4D_IsPlayerGhost(target))
	{
		L4D_ReplaceWithBot(target);
	}

	// 把目标拉到坦克的位置（参考 raziEiL l4d_tank_pass 的快速移交流程）
	float vPos[3], vAng[3];
	GetClientAbsOrigin(tank, vPos);
	GetClientAbsAngles(tank, vAng);
	TeleportEntity(target, vPos, vAng, NULL_VECTOR);

	g_bInternalTransfer = true;
	g_bPanelShown = true;   // 新控制者不再自动弹面板
	L4D_ReplaceTank(tank, target);
	g_bInternalTransfer = false;

	// 与 l4d_tank_control_eq 相同：避免移交后引擎多段控制判定异常
	L4D2Direct_SetTankPassedCount(1);

	CPrintToChat(target, "{blue}[坦克]{default} 队内投票通过，你已接管坦克！");
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

bool IsCurrentTank(int client)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return false;

	if (GetClientTeam(client) != TEAM_INFECTED || !IsPlayerAlive(client))
		return false;

	return GetEntProp(client, Prop_Send, "m_zombieClass") == ZOMBIECLASS_TANK && !L4D_IsPlayerGhost(client);
}

bool IsValidVoteTarget(int client)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return false;

	if (GetClientTeam(client) != TEAM_INFECTED)
		return false;

	// 不能是另一个还活着、正在操控坦克的玩家
	if (IsPlayerAlive(client) && GetEntProp(client, Prop_Send, "m_zombieClass") == ZOMBIECLASS_TANK && !L4D_IsPlayerGhost(client))
		return false;

	return true;
}

void AnnounceToInfected(const char[] sFormat, any ...)
{
	char sBuffer[256];
	VFormat(sBuffer, sizeof(sBuffer), sFormat, 2);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == TEAM_INFECTED)
			CPrintToChat(i, "%s", sBuffer);
	}
}

// ---------------------------------------------------------------------------
// 定时器
// ---------------------------------------------------------------------------

Action Timer_InitialCheck(Handle timer)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsCurrentTank(i))
		{
			ShowPassPanel(i);
			break;
		}
	}

	return Plugin_Stop;
}

Action Timer_DelayedPanel(Handle timer, DataPack dp)
{
	dp.Reset();
	int client = GetClientOfUserId(dp.ReadCell());
	delete dp;

	if (client > 0)
		ShowPassPanel(client);

	return Plugin_Stop;
}
