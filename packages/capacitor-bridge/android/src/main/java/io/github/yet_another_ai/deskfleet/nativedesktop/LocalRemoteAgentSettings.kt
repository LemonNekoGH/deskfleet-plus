package io.github.yet_another_ai.deskfleet.nativedesktop

import org.json.JSONObject
import java.io.File
import java.util.UUID

internal data class RemoteAgentSettingsState(
    val allowRead: Boolean = false,
    val allowOperate: Boolean = false,
    val allowSessions: Boolean = false,
    val allowWorkspaces: Boolean = false,
    val allowSuperAgent: Boolean = false,
    val allowLocalCrossWorkspace: Boolean = false,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("allowRead", allowRead)
        .put("allowOperate", allowOperate)
        .put("allowSessions", allowSessions)
        .put("allowWorkspaces", allowWorkspaces)
        .put("allowSuperAgent", allowSuperAgent)
        .put("allowLocalCrossWorkspace", allowLocalCrossWorkspace)
}

/**
 * Reads and persists `/var/lib/deskfleet/remote-agent-settings.json` inside the
 * embedded container's bind-mounted data directory (`filesDir/linux/data`).
 */
internal class LocalRemoteAgentSettings(private val dataDir: File) {
    private val settingsFile = File(dataDir, FILENAME)

    fun read(): RemoteAgentSettingsState {
        if (!settingsFile.isFile) {
            return RemoteAgentSettingsState()
        }
        val raw = settingsFile.readText(Charsets.UTF_8)
        return fromJson(JSONObject(raw))
    }

    fun write(settings: RemoteAgentSettingsState): RemoteAgentSettingsState {
        dataDir.mkdirs()
        val tempFile = File(dataDir, "$FILENAME.${UUID.randomUUID()}.tmp")
        try {
            tempFile.writeText(settings.toJson().toString(2) + "\n", Charsets.UTF_8)
            tempFile.setReadable(false, false)
            tempFile.setReadable(true, true)
            tempFile.setWritable(false, false)
            tempFile.setWritable(true, true)
            if (!tempFile.renameTo(settingsFile)) {
                tempFile.copyTo(settingsFile, overwrite = true)
            }
            settingsFile.setReadable(false, false)
            settingsFile.setReadable(true, true)
            settingsFile.setWritable(false, false)
            settingsFile.setWritable(true, true)
            return settings
        } finally {
            if (tempFile.exists()) {
                tempFile.delete()
            }
        }
    }

    companion object {
        const val FILENAME = "remote-agent-settings.json"
        private const val VALIDATION_ERROR =
            "Remote Agent settings must contain boolean read, operate, session and workspace preferences"

        fun fromFilesDir(filesDir: File): LocalRemoteAgentSettings =
            LocalRemoteAgentSettings(File(filesDir, "linux/data"))

        fun fromJson(json: JSONObject): RemoteAgentSettingsState {
            val allowedKeys = setOf(
                "allowRead",
                "allowOperate",
                "allowSessions",
                "allowWorkspaces",
                "allowSuperAgent",
                "allowLocalCrossWorkspace",
            )
            val headlessOptionalOnlyKeys = setOf("allowSuperAgent", "allowLocalCrossWorkspace")
            val presentKeys = mutableListOf<String>()
            val keys = json.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                if (key !in allowedKeys) {
                    throw IllegalArgumentException(VALIDATION_ERROR)
                }
                presentKeys.add(key)
            }
            val headlessPartial = presentKeys.isNotEmpty() && presentKeys.all { it in headlessOptionalOnlyKeys }
            val allowRead = if (headlessPartial) false else requireBoolean(json, "allowRead")
            val allowOperate = if (headlessPartial) false else requireBoolean(json, "allowOperate")
            val allowSessions = optionalBoolean(json, "allowSessions")
            val allowWorkspaces = optionalBoolean(json, "allowWorkspaces")
            val allowSuperAgent = optionalBoolean(json, "allowSuperAgent")
            val allowLocalCrossWorkspace = optionalBoolean(json, "allowLocalCrossWorkspace")
            return RemoteAgentSettingsState(
                allowRead = allowRead,
                allowOperate = allowOperate,
                allowSessions = allowSessions,
                allowWorkspaces = allowWorkspaces,
                allowSuperAgent = allowSuperAgent,
                allowLocalCrossWorkspace = allowLocalCrossWorkspace,
            )
        }

        private fun requireBoolean(json: JSONObject, key: String): Boolean {
            if (!json.has(key)) {
                throw IllegalArgumentException(VALIDATION_ERROR)
            }
            return (json.opt(key) as? Boolean) ?: throw IllegalArgumentException(VALIDATION_ERROR)
        }

        private fun optionalBoolean(json: JSONObject, key: String): Boolean {
            if (!json.has(key)) {
                return false
            }
            return (json.opt(key) as? Boolean) ?: throw IllegalArgumentException(VALIDATION_ERROR)
        }
    }
}
