#pragma newdecls required

#include <sourcemod>

/******************************************************************
*
* v1.0
* ------------------------
* ------- Details: -------
* ------------------------
* - Establishes Server Commands for the following:
* --> Unloading Plugins with the argument being the folder you want to unload the plugins from, leave the argument empty if you wish to unload just the main folder.
* --> Reserving Plugins, meaning these plugins will not be unloaded when the previously mentioned Plugin Unload is unloading the folder these plugins reside in.
* --> Unloading Reserved Plugins, this function will unload the reserved plugins in the order from "Last Reserved" to "First Reserved".

* v1.1
* ------------------------
* ------- Details: -------
* ------------------------
* - Overhauled it with keyCat's feedback in mind.
* --> Unloading Plugins with the pred_unload_plugins will push all currently loaded plugins to the Array and unloads them from Last loaded to First loaded. This way, dependencies should'nt be an issue.
* --> Removed the possibility of just Unloading Reserved Plugins... as there's no need for it?
*
*
* v1.2
* ------------------------
* ------- Details: -------
* ------------------------
* - Removed the unnecessary "ReservePlugin" function.
* - Added a failsafe after plugins are supposed to be unloaded, as we've seen some cases where this plugin would be the only one refusing to unload, thus never refreshing the plugins.
* - Added a less messy way of preventing double pushing, as this plugin is the only one that could possibly be double pushed. (StrEqual instead of FindInArray for every single plugin)
*
*
* v1.2.1
* ------------------------
* ------- Details: -------
* ------------------------
* - Removed the unnecessary "ReservePlugin" function.
* - Added a failsafe after plugins are supposed to be unloaded, as we've seen some cases where this plugin would be the only one refusing to unload, thus never refreshing the plugins.
* - Added a less messy way of preventing double pushing, as this plugin is the only one that could possibly be double pushed. (StrEqual instead of FindInArray for every single plugin)
*
* v1.2.2
* ------------------------
* ------- Details: -------
* ------------------------
* - Added sPlugin which will store this plugin's path on load, rather than looking it up during the "UnloadPlugins" function.
* - Added Timers for closing functionality of UnloadPlugins to ensure accuracy.
*
* v1.2.3
* ------------------------
* - Unload commands are now issued in small batches (BATCH_SIZE per batch + a sentinel command)
*   instead of one big burst of ~150 commands. The burst could overflow the engine command buffer;
*   the dropped tail was then replayed late by command_buffer.smx AFTER "sm plugins refresh" had
*   already run, silently unloading early-loaded plugins (left4dhooks.smx etc.) with no log entry.
*
***************************************************************************************************************************************************************************************************
* ------------------------
* -------- NOTES: --------
* ------------------------
* - The plugin doesn't currently care about capitalization other than the Directory of the plugin, not sure if I can be bothered adding this :P
*
******************************************************************/

#define BATCH_SIZE 20 // Safe margin: the engine command buffer fit ~127 unload commands before overflowing.

Handle aReservedPlugins;
char sPlugin[PLATFORM_MAX_PATH];

int g_iUnloadCursor = -1;
bool g_bUnloading = false;

public Plugin myinfo = 
{
	name = "Predictable Plugin Unloader",
	author = "Sir (heavily influenced by keyCat)",
	version = "1.2.3",
	description = "Allows for unloading plugins from last to first."
}

public void OnPluginStart()
{
	RegServerCmd("pred_unload_plugins", UnloadPlugins, "Unload Plugins!");
	RegServerCmd("pred_unload_continue", ContinueUnload, "Continue the batched unload. (Internal)");

	// Gotta reserve ourself of course.
	// - Supports moving the plugin to another folder. (INVALID_HANDLE simply gets the calling plugin)
	GetPluginFilename(INVALID_HANDLE, sPlugin, sizeof(sPlugin));

	// Reserved Plugins
	aReservedPlugins = CreateArray(PLATFORM_MAX_PATH);
}

Action UnloadPlugins(int args) 
{
	char stockpluginname[64];
	Handle pluginIterator = GetPluginIterator();
	Handle currentPlugin;

	while (MorePlugins(pluginIterator))
	{
		currentPlugin = ReadPlugin(pluginIterator);
		GetPluginFilename(currentPlugin, stockpluginname, sizeof(stockpluginname));

		// We're not pushing this plugin itself into the array as we'll unload it on a timer at the end.
		if (!StrEqual(sPlugin, stockpluginname)) 
		  PushArrayString(aReservedPlugins, stockpluginname);
	}

	CloseHandle(currentPlugin); // This one I probably don't have to close, but whatevs.
	CloseHandle(pluginIterator);

	ServerCommand("sm plugins load_unlock");

	// Issue the unloads in small batches. Dumping all ~150 "sm plugins unload" commands at once
	// could overflow the engine command buffer; the dropped tail was replayed late by command_buffer.smx
	// after "sm plugins refresh" had already run, silently unloading early-loaded plugins
	// (left4dhooks.smx and friends) with no log entry.
	g_iUnloadCursor = GetArraySize(aReservedPlugins);
	g_bUnloading = true;
	IssueUnloadBatch();

	return Plugin_Handled;
}

void IssueUnloadBatch()
{
	char sReserved[PLATFORM_MAX_PATH];

	for (int iIssued = 0; iIssued < BATCH_SIZE && g_iUnloadCursor > 0; iIssued++)
	{
		g_iUnloadCursor--; // Unload from last loaded to first loaded.
		GetArrayString(aReservedPlugins, g_iUnloadCursor, sReserved, sizeof(sReserved));
		ServerCommand("sm plugins unload %s", sReserved);
	}

	if (g_iUnloadCursor > 0)
	{
		// The command buffer executes in order, so this sentinel runs only after the batch above is done.
		ServerCommand("pred_unload_continue");
	}
	else
	{
		g_bUnloading = false;

		// Refresh first, then unload this plugin.
		// Using Timers because these are time crucial and ServerCommands aren't a 100% reliable in terms of execution order.
		CreateTimer(0.1, RefreshPlugins);
		CreateTimer(0.5, UnloadSelf);
	}
}

Action ContinueUnload(int args)
{
	if (!g_bUnloading)
		return Plugin_Handled;

	IssueUnloadBatch();

	return Plugin_Handled;
}

Action RefreshPlugins(Handle timer)
{
	ServerCommand("sm plugins refresh");

	return Plugin_Stop;
}

Action UnloadSelf(Handle timer)
{
	ServerCommand("sm plugins unload %s", sPlugin);

	return Plugin_Stop;
}
