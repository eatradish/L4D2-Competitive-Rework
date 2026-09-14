// =============================================================================
// l4d2_vote_guard.sp - 踢人投票接管 + 投票仲裁（!veto / !votepass）
//
// 解决的问题：
//   1) 游戏原生的 "投票踢人"（客户端 callvote Kick）没人管：
//      普通玩家可以对任何人发起，包括管理员；而且引擎投票一旦开跑，
//      SourceMod 侧没有取消接口（SM 的 CancelVote() 只管 SM 自己那套投票，
//      builtinvotes 的 CancelBuiltinVote() 只管它自己创建的票）。
//   2) 我们不喜欢"用菜单当投票界面"的方案（Hubfront 那套走 SM 菜单），
//      想要 L4D2 的原生投票面板。
//
// 做法（全接管）：
//   * 监听 callvote，把所有 Kick 投票在"发起"这一步拦下来，改用 builtinvotes
//     扩展重新发起一次同样的投票 —— 显示的就是 L4D2 原生投票面板
//     （和仓库里 readyup / 坦克移交同一套机制，不是菜单）。
//   * 拦截时做权限检查：自踢 / 踢 bot / 跨队 / 管理员保护 / 免疫等级 /
//     投票冷却 / 已有投票进行中。拒绝的话直接把手里的原生投票吞掉。
//   * !vk       ：人人可用的踢人投票入口 —— 不带参数弹选人菜单，
//                 !vk <名字|#userid> 直接发起；和 callvote 走同一套检查、
//                 同一个原生投票面板。
//   * !veto     ：否决进行中的投票（默认也能管其它插件发起的 builtinvotes 投票）；
//                 投票已通过、踢出还排在执行队列上的时候，也能把这次踢出撤销。
//   * !votepass ：强制通过我们发起的踢人投票（其它插件的投票没有外部强制接口，
//                 拿不到它们的 vote handle，只能用 !veto 取消）。
//
// 为什么用 BuiltinVoteType_Custom_YesNo 而不是 BuiltinVoteType_Kick：
//   Kick 类型固定走游戏的 "#L4D_vote_kick_player" 翻译串，文案不可控；
//   Custom_YesNo + 自写标题 = 和 l4d2_tank_pass.sp 完全相同的成熟写法。
//
// 注意事项：
//   * 拦截只发生在"发起"阶段，换图/换难度等其它 callvote 保持原生流程。
//   * 投票池 = 非 bot、非观战者（比赛里教练/旁观不该左右投票）。
//   * 投票通过后由本插件 KickClient() 踢人（原生投票则由引擎踢）。
// =============================================================================

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <colors>
#include <builtinvotes>

#define PLUGIN_VERSION "1.0.0"

#define TEAM_SPECTATOR 1

// 投票通过后到真正踢出的间隔：留一拍让管理员能用 !veto 撤销
#define KICK_EXEC_DELAY 1.0

ConVar g_cvEnable;
ConVar g_cvVoteTime;
ConVar g_cvDelay;
ConVar g_cvFlag;
ConVar g_cvProtectAdmins;
ConVar g_cvImmunity;
ConVar g_cvSameTeam;
ConVar g_cvBots;
ConVar g_cvSpecVote;
ConVar g_cvMajority;
ConVar g_cvVetoAny;
ConVar g_cvAnnounce;

bool   g_bVoteActive;      // 我们发起的踢人投票进行中
bool   g_bVetoed;          // 被 !veto 否决
bool   g_bForced;          // 被 !votepass 强制通过
bool   g_bKickPending;     // 投票已通过，踢出动作还排在定时器上（!veto 可以撤销）
int    g_iPendingUserId;   // 待踢出的目标 userid
int    g_iInitiator;       // 发起者 client index
int    g_iTarget;          // 目标 client index
Handle g_hVote;            // 当前踢人投票 handle
int    g_iCooldownUntil;   // 时间戳：在此之前不允许新的踢人投票

public Plugin myinfo =
{
	name        = "[L4D2] Vote Guard",
	author      = "L4D2-Comp-Source",
	description = "接管踢人投票（原生面板）+ !vk / !veto / !votepass",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cvEnable        = CreateConVar("sm_voteguard_enable", "1", "接管踢人投票（0 = 完全走游戏原生流程）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvVoteTime      = CreateConVar("sm_voteguard_time", "30", "投票时长（秒）", FCVAR_NOTIFY, true, 5.0, true, 60.0);
	g_cvDelay         = CreateConVar("sm_voteguard_delay", "30", "两次踢人投票之间的最短间隔（秒）", FCVAR_NOTIFY, true, 0.0, true, 600.0);
	g_cvFlag          = CreateConVar("sm_voteguard_flag", "d", "使用 !veto / !votepass 所需的权限 flag（d = Ban）");
	g_cvProtectAdmins = CreateConVar("sm_voteguard_protect_admins", "1", "1 = 非管理员不能投票踢管理员", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvImmunity      = CreateConVar("sm_voteguard_immunity", "1", "1 = 免疫等级低的人不能发起踢免疫等级高的人的投票", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvSameTeam      = CreateConVar("sm_voteguard_sameteam", "1", "1 = 只能投票踢同队玩家", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvBots          = CreateConVar("sm_voteguard_bots", "0", "1 = 允许投票踢 bot", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvSpecVote      = CreateConVar("sm_voteguard_specvote", "0", "1 = 允许观战者发起踢人投票", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvMajority      = CreateConVar("sm_voteguard_majority", "0", "通过规则：0 = 同意票 > 反对票；1 = 同意票 > 可投票人数的一半", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvVetoAny       = CreateConVar("sm_voteguard_veto_any", "1", "1 = !veto 也能取消其它插件发起的 builtinvotes 投票（readyup / 坦克移交等）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvAnnounce      = CreateConVar("sm_voteguard_announce", "1", "1 = 在聊天框播报投票发起 / 结果", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	AutoExecConfig(true, "l4d2_vote_guard");

	LoadTranslations("common.phrases"); // FindTarget 的报错文案

	RegConsoleCmd("sm_vk", Command_VoteKick, "发起踢人投票（人人可用；不带参数弹出选人菜单）");
	RegConsoleCmd("sm_veto", Command_Veto, "取消当前进行中的投票（需要权限 flag，默认 d）");
	RegConsoleCmd("sm_votepass", Command_VotePass, "强制通过进行中的踢人投票（需要权限 flag，默认 d）");

	AddCommandListener(Listener_CallVote, "callvote");
}

// ---------------------------------------------------------------------------
// 拦截原生踢人投票
// ---------------------------------------------------------------------------

public Action Listener_CallVote(int client, const char[] command, int argc)
{
	if (!g_cvEnable.BoolValue)
		return Plugin_Continue;

	if (argc < 2)
		return Plugin_Continue;

	char sType[16];
	GetCmdArg(1, sType, sizeof(sType));

	// 只管 Kick，其它 callvote（换图 / 换难度 / 回大厅等）保持原生流程
	if (!StrEqual(sType, "Kick", false))
		return Plugin_Continue;

	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Handled;

	if (!g_cvSpecVote.BoolValue && GetClientTeam(client) <= TEAM_SPECTATOR)
	{
		RejectVoteRequest(client, "观战者不能发起踢人投票。");
		return Plugin_Handled;
	}

	// 第二个参数形如 "12" 或 "12 原因"（见 pause.sp 里对同一条命令的解析）
	char sArg[64];
	GetCmdArg(2, sArg, sizeof(sArg));

	int iUserId = ParseVoteUserId(sArg);
	int target = (iUserId > 0) ? GetClientOfUserId(iUserId) : 0;

	if (!ValidateKickRequest(client, target))
		return Plugin_Handled;

	// 统一拦下原生投票，交给定时器重发为 builtinvotes 投票
	// （不在客户端命令回调里直接开投票，避免和引擎投票流程打架）
	ScheduleKickVote(client, target);

	return Plugin_Handled;
}

public Action Timer_StartKickVote(Handle timer, DataPack dp)
{
	dp.Reset();
	int initiator = GetClientOfUserId(dp.ReadCell());
	int target = GetClientOfUserId(dp.ReadCell());
	delete dp;

	if (!g_cvEnable.BoolValue)
		return Plugin_Stop;

	if (initiator < 1 || target < 1 || !IsClientInGame(initiator) || !IsClientInGame(target))
		return Plugin_Stop;

	// 排队期间状态可能已经变了
	if (g_bVoteActive || IsBuiltinVoteInProgress() || GetTime() < g_iCooldownUntil)
	{
		CPrintToChat(initiator, "{green}[投票]{default} 已经有投票在进行中了，请稍后再试。");
		return Plugin_Stop;
	}

	StartKickVote(initiator, target);
	return Plugin_Stop;
}

void StartKickVote(int initiator, int target)
{
	// 投票池 = 非 bot、非观战者
	int iEligible = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) > TEAM_SPECTATOR)
			iEligible++;
	}

	if (iEligible < 2)
	{
		CPrintToChat(initiator, "{green}[投票]{default} 可参与投票的玩家不足，无法发起投票。");
		return;
	}

	g_bVoteActive = true;
	g_bVetoed = false;
	g_bForced = false;
	g_iInitiator = initiator;
	g_iTarget = target;

	int iTime = g_cvVoteTime.IntValue;

	char sTitle[128];
	FormatEx(sTitle, sizeof(sTitle), "是否踢出玩家 %N ？", target);

	g_hVote = CreateBuiltinVote(Handler_KickVote, BuiltinVoteType_Custom_YesNo,
		BuiltinVoteAction_Cancel | BuiltinVoteAction_VoteEnd | BuiltinVoteAction_End);

	if (g_hVote == null)
	{
		// 被 OnBuiltinVoteCreate forward 拦了，或者扩展抽风
		g_bVoteActive = false;
		g_iInitiator = 0;
		g_iTarget = 0;

		CPrintToChat(initiator, "{green}[投票]{default} 投票创建失败，请稍后再试。");
		LogMessage("[VoteGuard] CreateBuiltinVote 返回空句柄，踢人投票未开始（发起者 %L）", initiator);
		return;
	}

	SetBuiltinVoteArgument(g_hVote, sTitle);
	SetBuiltinVoteInitiator(g_hVote, initiator);
	SetBuiltinVoteResultCallback(g_hVote, Handler_KickVoteResult);

	if (!DisplayBuiltinVoteToAllNonSpectators(g_hVote, iTime))
	{
		// 基本进不来（前面已经查过没有其它投票在跑），防御一下
		LogMessage("[VoteGuard] 投票显示失败，本次踢人投票作废（发起者 %L）", initiator);

		g_bVoteActive = false;
		g_iInitiator = 0;
		g_iTarget = 0;

		Handle hVote = g_hVote;
		g_hVote = null;
		delete hVote;

		CPrintToChat(initiator, "{green}[投票]{default} 投票没能发起，请稍后再试。");
		return;
	}

	// 和原生踢人投票一致：发起者默认投同意
	if (!IsFakeClient(initiator) && GetClientTeam(initiator) > TEAM_SPECTATOR)
		FakeClientCommand(initiator, "Vote Yes");

	if (g_cvAnnounce.BoolValue)
	{
		CPrintToChatAll("{green}[投票]{default} {olive}%N{default} 发起了踢出 {olive}%N{default} 的投票（%d 秒，F1 同意 / F2 反对）。",
			initiator, target, iTime);
	}

	LogMessage("[VoteGuard] %L 发起踢人投票，目标 %L", initiator, target);
}

// ---------------------------------------------------------------------------
// !vk：人人可用的踢人投票入口（不带参数弹选人菜单）
// ---------------------------------------------------------------------------

public Action Command_VoteKick(int client, int args)
{
	if (client == 0 || !IsClientInGame(client))
	{
		ReplyToCommand(client, "[SM] 只能在游戏里使用该命令。");
		return Plugin_Handled;
	}

	if (!g_cvEnable.BoolValue)
	{
		ReplyToCommand(client, "[SM] 投票接管已关闭（sm_voteguard_enable 0），请用游戏自带的投票菜单。");
		return Plugin_Handled;
	}

	if (!g_cvSpecVote.BoolValue && GetClientTeam(client) <= TEAM_SPECTATOR)
	{
		RejectVoteRequest(client, "观战者不能发起踢人投票。");
		return Plugin_Handled;
	}

	// !vk —— 弹出选人菜单
	if (args < 1)
	{
		ShowKickTargetMenu(client);
		return Plugin_Handled;
	}

	// !vk <名字|#userid> —— 直接发起（名字允许带空格，先去掉引号）
	char sArg[MAX_NAME_LENGTH];
	GetCmdArgString(sArg, sizeof(sArg));
	StripQuotes(sArg);

	// nobots=false（由本插件自己判断 bot）、immunity=false（管理员保护也由本插件判断，提示更清楚）
	int target = FindTarget(client, sArg, false, false);
	if (target < 1)
		return Plugin_Handled; // FindTarget 已经报过原因

	if (!ValidateKickRequest(client, target))
		return Plugin_Handled;

	ScheduleKickVote(client, target);
	return Plugin_Handled;
}

void ShowKickTargetMenu(int client)
{
	Menu menu = new Menu(MenuHandler_KickTarget, MENU_ACTIONS_DEFAULT);
	menu.SetTitle("选择要踢出的玩家");

	char sInfo[16];
	int iCount = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || i == client)
			continue;

		// 菜单里就按实际规则过滤，避免列出来一堆踢不了的
		if (IsFakeClient(i) && !g_cvBots.BoolValue)
			continue;

		if (g_cvSameTeam.BoolValue && GetClientTeam(i) != GetClientTeam(client))
			continue;

		char sDisplay[MAX_NAME_LENGTH + 32];
		if (GetClientTeam(i) <= TEAM_SPECTATOR)
			FormatEx(sDisplay, sizeof(sDisplay), "%N（观战）", i);
		else if (GetClientTeam(i) == 2)
			FormatEx(sDisplay, sizeof(sDisplay), "%N（生还者）", i);
		else
			FormatEx(sDisplay, sizeof(sDisplay), "%N（感染者）", i);

		IntToString(GetClientUserId(i), sInfo, sizeof(sInfo));
		menu.AddItem(sInfo, sDisplay);
		iCount++;
	}

	if (iCount == 0)
	{
		delete menu;
		CPrintToChat(client, "{green}[投票]{default} 没有可以投票踢出的玩家。");
		return;
	}

	menu.Display(client, 20);
}

public int MenuHandler_KickTarget(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_End:
		{
			delete menu;
		}
		case MenuAction_Select:
		{
			char sInfo[16];
			if (!menu.GetItem(param2, sInfo, sizeof(sInfo)))
				return 0;

			if (IsClientInGame(param1))
			{
				int target = GetClientOfUserId(StringToInt(sInfo));

				// 选完再校验一遍（这期间可能有人离开 / 起了别的投票）
				if (ValidateKickRequest(param1, target))
					ScheduleKickVote(param1, target);
			}
		}
	}

	return 0;
}

// ---------------------------------------------------------------------------
// 投票回调
// ---------------------------------------------------------------------------

public void Handler_KickVote(Handle vote, BuiltinVoteAction action, int param1, int param2)
{
	switch (action)
	{
		case BuiltinVoteAction_End:
		{
			g_hVote = null;
			delete vote;

			// 兜底：没有经过结果回调就结束（例如系统取消）
			if (g_bVoteActive)
			{
				g_bVoteActive = false;
				g_iCooldownUntil = GetTime() + g_cvDelay.IntValue;
			}

			g_iInitiator = 0;
			g_iTarget = 0;
			g_bVetoed = false;
			g_bForced = false;
		}
		case BuiltinVoteAction_Cancel:
		{
			// 投票被系统取消（被别的投票顶掉 / 发起者断线等），或我们自己取消
			if (g_bVoteActive)
			{
				g_bVoteActive = false;
				g_iCooldownUntil = GetTime() + g_cvDelay.IntValue;

				if (g_bVetoed)
				{
					// !veto 已经播报过，这里不再刷屏
					LogMessage("[VoteGuard] 踢人投票被 !veto 取消（目标 %L）", g_iTarget);
				}
				else if (g_cvAnnounce.BoolValue)
				{
					CPrintToChatAll("{green}[投票]{default} 踢人投票已取消。");
					LogMessage("[VoteGuard] 踢人投票被系统取消 (reason %d)", param1);
				}
			}

			g_bVoteActive = false;

			// 必须回一个 Pass/Fail 才能清掉没投票玩家的投票面板
			DisplayBuiltinVoteFail(vote, view_as<BuiltinVoteFailReason>(param1));
		}
	}
}

public void Handler_KickVoteResult(Handle vote, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info)
{
	// 被 !votepass 强制结束的，不再走正常结算
	if (!g_bVoteActive || g_bForced)
		return;

	int yes = 0;
	int no = 0;

	for (int i = 0; i < num_items; i++)
	{
		if (item_info[i][BUILTINVOTEINFO_ITEM_INDEX] == BUILTINVOTES_VOTE_YES)
			yes = item_info[i][BUILTINVOTEINFO_ITEM_VOTES];
		else if (item_info[i][BUILTINVOTEINFO_ITEM_INDEX] == BUILTINVOTES_VOTE_NO)
			no = item_info[i][BUILTINVOTEINFO_ITEM_VOTES];
	}

	int initiator = g_iInitiator;
	int target = g_iTarget;

	g_bVoteActive = false;
	g_iCooldownUntil = GetTime() + g_cvDelay.IntValue;

	// 目标在投票过程中已经不可用
	if (target < 1 || !IsClientInGame(target))
	{
		DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Generic);
		return;
	}

	bool bPassed = g_cvMajority.BoolValue ? (yes > num_clients / 2) : (yes > no);

	if (bPassed)
	{
		char sBuffer[128];
		FormatEx(sBuffer, sizeof(sBuffer), "投票通过：踢出玩家 %N", target);
		DisplayBuiltinVotePass(vote, sBuffer);

		if (g_cvAnnounce.BoolValue)
			CPrintToChatAll("{green}[投票]{default} 投票通过（同意 %d / 反对 %d），{olive}%N{default} 将被踢出。", yes, no, target);

		LogMessage("[VoteGuard] 踢人投票通过（同意 %d / 反对 %d）：%L -> %L", yes, no, initiator, target);

		// 先排队，1 秒后再踢：这段窗口里 !veto 可以把踢出撤销（否决语义）
		g_bKickPending = true;
		g_iPendingUserId = GetClientUserId(target);
		CreateTimer(KICK_EXEC_DELAY, Timer_KickTarget, g_iPendingUserId, TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);

		if (g_cvAnnounce.BoolValue)
			CPrintToChatAll("{green}[投票]{default} 踢人投票未通过（同意 %d / 反对 %d）。", yes, no);

		LogMessage("[VoteGuard] 踢人投票未通过（同意 %d / 反对 %d）：%L -> %L", yes, no, initiator, target);
	}
}

public Action Timer_KickTarget(Handle timer, int iUserId)
{
	// 被 !veto 撤销掉的不再执行（!votepass 和正常通过共用这条路径）
	if (!g_bKickPending || iUserId != g_iPendingUserId)
		return Plugin_Stop;

	g_bKickPending = false;
	g_iPendingUserId = 0;

	int target = GetClientOfUserId(iUserId);

	if (target > 0 && IsClientInGame(target))
	{
		KickClient(target, "你已被投票踢出");
		LogMessage("[VoteGuard] 执行踢出：%L", target);
	}

	return Plugin_Stop;
}

// ---------------------------------------------------------------------------
// !veto / !votepass
// ---------------------------------------------------------------------------

public Action Command_Veto(int client, int args)
{
	if (!HasVoteAccess(client))
	{
		ReplyToCommand(client, "[SM] 你没有权限使用该命令。");
		return Plugin_Handled;
	}

	// 1) 我们自己发起的踢人投票
	if (g_bVoteActive && g_hVote != null)
	{
		int target = g_iTarget;
		g_bVetoed = true;

		char sAdmin[MAX_NAME_LENGTH];
		FormatAdminName(client, sAdmin, sizeof(sAdmin));

		if (g_cvAnnounce.BoolValue)
			CPrintToChatAll("{green}[投票]{default} {olive}%s{default} 否决了踢出 {olive}%N{default} 的投票。", sAdmin, target);

		LogMessage("[VoteGuard] %L 用 !veto 否决了踢人投票（目标 %L）", client, target);

		CancelBuiltinVote();
		return Plugin_Handled;
	}

	// 2) 投票已经通过、踢出动作还排在定时器上 —— 否决可以直接撤销
	if (g_bKickPending)
	{
		int target = GetClientOfUserId(g_iPendingUserId);

		g_bKickPending = false;
		g_iPendingUserId = 0;

		char sAdmin2[MAX_NAME_LENGTH];
		FormatAdminName(client, sAdmin2, sizeof(sAdmin2));

		if (g_cvAnnounce.BoolValue)
		{
			if (target > 0)
				CPrintToChatAll("{green}[投票]{default} {olive}%s{default} 否决了这次投票：虽然已通过，踢出 {olive}%N{default} 已撤销。", sAdmin2, target);
			else
				CPrintToChatAll("{green}[投票]{default} {olive}%s{default} 否决了这次投票，踢出已撤销。", sAdmin2);
		}

		LogMessage("[VoteGuard] %L 用 !veto 否决了已通过的踢人投票（目标 %L，踢出已撤销）", client, target);
		return Plugin_Handled;
	}

	// 3) 其它插件发起的 builtinvotes 投票（readyup / 坦克移交等）
	if (IsBuiltinVoteInProgress())
	{
		if (!g_cvVetoAny.BoolValue)
		{
			ReplyToCommand(client, "[SM] 当前是其它插件的投票，本命令只处理踢人投票。");
			return Plugin_Handled;
		}

		char sAdmin[MAX_NAME_LENGTH];
		FormatAdminName(client, sAdmin, sizeof(sAdmin));

		if (g_cvAnnounce.BoolValue)
			CPrintToChatAll("{green}[投票]{default} {olive}%s{default} 取消了当前投票。", sAdmin);

		LogMessage("[VoteGuard] %L 用 !veto 取消了其它插件的 builtinvotes 投票", client);

		CancelBuiltinVote();
		return Plugin_Handled;
	}

	// 4) SM 自己的投票（basevotes 那套，管理员命令发起）
	if (IsVoteInProgress())
	{
		CancelVote();

		char sAdmin[MAX_NAME_LENGTH];
		FormatAdminName(client, sAdmin, sizeof(sAdmin));

		if (g_cvAnnounce.BoolValue)
			CPrintToChatAll("{green}[投票]{default} {olive}%s{default} 取消了当前投票。", sAdmin);

		LogMessage("[VoteGuard] %L 用 !veto 取消了 SM 投票", client);
		return Plugin_Handled;
	}

	ReplyToCommand(client, "[SM] 当前没有进行中的投票。");
	return Plugin_Handled;
}

public Action Command_VotePass(int client, int args)
{
	if (!HasVoteAccess(client))
	{
		ReplyToCommand(client, "[SM] 你没有权限使用该命令。");
		return Plugin_Handled;
	}

	if (!g_bVoteActive || g_hVote == null)
	{
		ReplyToCommand(client, "[SM] 没有进行中的踢人投票（其它插件的投票没有外部强制通过接口，只能用 !veto 取消）。");
		return Plugin_Handled;
	}

	int target = g_iTarget;

	if (target < 1 || !IsClientInGame(target))
	{
		ReplyToCommand(client, "[SM] 目标玩家已不在游戏中。");
		return Plugin_Handled;
	}

	g_bForced = true;
	g_bVoteActive = false;
	g_iCooldownUntil = GetTime() + g_cvDelay.IntValue;

	char sBuffer[128];
	FormatEx(sBuffer, sizeof(sBuffer), "投票通过（管理员强制）：踢出玩家 %N", target);
	DisplayBuiltinVotePass(g_hVote, sBuffer);

	char sAdmin[MAX_NAME_LENGTH];
	FormatAdminName(client, sAdmin, sizeof(sAdmin));

	if (g_cvAnnounce.BoolValue)
		CPrintToChatAll("{green}[投票]{default} {olive}%s{default} 强制通过了踢出 {olive}%N{default} 的投票。", sAdmin, target);

	LogMessage("[VoteGuard] %L 用 !votepass 强制通过踢人投票（目标 %L）", client, target);

	g_bKickPending = true;
	g_iPendingUserId = GetClientUserId(target);
	CreateTimer(KICK_EXEC_DELAY, Timer_KickTarget, g_iPendingUserId, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------

// 解析 "callvote Kick" 的第二个参数：取开头的 userid（"12" / "12 原因" 都行）
int ParseVoteUserId(const char[] sArg)
{
	char sBuffer[32];
	int i = 0;

	while (sArg[i] != '\0' && i < sizeof(sBuffer) - 1)
	{
		if (sArg[i] == ' ' || sArg[i] == '\t')
			break;

		sBuffer[i] = sArg[i];
		i++;
	}

	sBuffer[i] = '\0';
	return StringToInt(sBuffer);
}

// !veto / !votepass 的权限判定：cvar 里的 flag（默认 d）
bool HasVoteAccess(int client)
{
	if (client == 0)
		return true; // 服务器控制台

	char sFlag[8];
	g_cvFlag.GetString(sFlag, sizeof(sFlag));

	if (sFlag[0] == '\0')
		return false;

	AdminFlag flag;
	if (!FindFlagByChar(sFlag[0], flag))
		return false;

	return CheckCommandAccess(client, "sm_veto", 1 << view_as<int>(flag));
}

// 播报用：拿执行命令的管理员名字（client == 0 时是服务器控制台）
void FormatAdminName(int client, char[] sBuffer, int iMaxLen)
{
	if (client == 0)
	{
		strcopy(sBuffer, iMaxLen, "服务器控制台");
	}
	else
	{
		GetClientName(client, sBuffer, iMaxLen);
	}
}

// 发起前的统一校验（callvote 拦截 / !vk 命令 / 选人菜单共用）
// 被拒时会给发起者提示 + 记日志
bool ValidateKickRequest(int client, int target)
{
	if (target < 1 || !IsClientInGame(target))
	{
		RejectVoteRequest(client, "目标玩家已不在游戏中。");
		return false;
	}

	if (target == client)
	{
		RejectVoteRequest(client, "不能投票踢出自己。");
		return false;
	}

	if (IsFakeClient(target) && !g_cvBots.BoolValue)
	{
		RejectVoteRequest(client, "不能投票踢出电脑玩家。");
		return false;
	}

	if (g_cvSameTeam.BoolValue && GetClientTeam(target) != GetClientTeam(client))
	{
		RejectVoteRequest(client, "只能投票踢出同队玩家。");
		return false;
	}

	AdminId aid = GetUserAdmin(client);
	AdminId tid = GetUserAdmin(target);

	if (g_cvProtectAdmins.BoolValue && tid != INVALID_ADMIN_ID && aid == INVALID_ADMIN_ID)
	{
		RejectVoteRequest(client, "对方是管理员，你没有权限发起针对他的投票。");
		return false;
	}

	if (g_cvImmunity.BoolValue)
	{
		int iClientImmunity = (aid != INVALID_ADMIN_ID) ? GetAdminImmunityLevel(aid) : 0;
		int iTargetImmunity = (tid != INVALID_ADMIN_ID) ? GetAdminImmunityLevel(tid) : 0;

		if (iClientImmunity < iTargetImmunity)
		{
			RejectVoteRequest(client, "对方的免疫等级高于你，无法发起投票。");
			return false;
		}
	}

	if (g_bVoteActive || IsBuiltinVoteInProgress())
	{
		RejectVoteRequest(client, "已经有一个投票在进行中。");
		return false;
	}

	int iNow = GetTime();
	if (iNow < g_iCooldownUntil)
	{
		RejectVoteRequest(client, "距离上一次投票还有 %d 秒。", g_iCooldownUntil - iNow);
		return false;
	}

	return true;
}

// 统一由定时器发起（不在命令回调里直接开投票，避免和引擎投票流程打架）
void ScheduleKickVote(int client, int target)
{
	DataPack dp = new DataPack();
	dp.WriteCell(GetClientUserId(client));
	dp.WriteCell(GetClientUserId(target));
	CreateTimer(0.1, Timer_StartKickVote, dp, TIMER_FLAG_NO_MAPCHANGE);
}

// 拒绝发起投票：给玩家提示 + 记日志
void RejectVoteRequest(int client, const char[] sFormat, any ...)
{
	char sMsg[192];
	VFormat(sMsg, sizeof(sMsg), sFormat, 3);

	CPrintToChat(client, "{green}[投票]{default} %s", sMsg);
	LogMessage("[VoteGuard] 拒绝 %L 的踢人投票：%s", client, sMsg);
}

// ---------------------------------------------------------------------------
// 状态维护
// ---------------------------------------------------------------------------

public void OnClientDisconnect(int client)
{
	if (!g_bVoteActive || g_hVote == null)
		return;

	// 目标是发起者的踢人对象，人走了投票没意义了
	if (client == g_iTarget)
	{
		g_bVoteActive = false;
		g_iCooldownUntil = GetTime() + g_cvDelay.IntValue;

		if (g_cvAnnounce.BoolValue)
			CPrintToChatAll("{green}[投票]{default} 目标玩家已离开游戏，踢人投票取消。");

		LogMessage("[VoteGuard] 目标 %L 在投票期间断线，取消投票", client);

		CancelBuiltinVote();
		return;
	}

	// 已经通过、还没执行的那位离开了：定时器自己会跳过，这里只清状态
	if (g_bKickPending && client == GetClientOfUserId(g_iPendingUserId))
	{
		g_bKickPending = false;
		g_iPendingUserId = 0;
	}
}

public void OnMapEnd()
{
	// 只清状态，handle 的清理交给 BuiltinVoteAction_End
	g_bVoteActive = false;
	g_bVetoed = false;
	g_bForced = false;
	g_bKickPending = false;
	g_iPendingUserId = 0;
	g_iInitiator = 0;
	g_iTarget = 0;
}

public void OnPluginEnd()
{
	// 插件被卸载时（例如 confogl 空服拆卸）把还在跑的投票收掉，
	// 避免客户端上留着一个没有主人的投票面板
	if (g_bVoteActive && g_hVote != null)
		CancelBuiltinVote();
}
