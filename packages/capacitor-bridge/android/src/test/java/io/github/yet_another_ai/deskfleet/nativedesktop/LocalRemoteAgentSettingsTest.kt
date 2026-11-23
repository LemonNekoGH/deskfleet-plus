package io.github.yet_another_ai.deskfleet.nativedesktop

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class LocalRemoteAgentSettingsTest {
    private val tempDir = Files.createTempDirectory("deskfleet-remote-agent-settings-test").toFile()

    @After
    fun cleanup() {
        tempDir.deleteRecursively()
    }

    @Test
    fun readReturnsDisabledDefaultsWhenFileOrDirectoryDoesNotExist() {
        val store = LocalRemoteAgentSettings.fromFilesDir(tempDir)
        assertEquals(
            RemoteAgentSettingsState(
                allowRead = false,
                allowOperate = false,
                allowSessions = false,
                allowWorkspaces = false,
            ),
            store.read(),
        )
    }

    @Test
    fun writePersistsAllFlagsAndCleansUpTempFiles() {
        val dataDir = File(tempDir, "linux/data")
        val store = LocalRemoteAgentSettings.fromFilesDir(tempDir)
        val updated = store.write(
            RemoteAgentSettingsState(
                allowRead = true,
                allowOperate = false,
                allowSessions = true,
                allowWorkspaces = true,
                allowSuperAgent = true,
                allowLocalCrossWorkspace = true,
            ),
        )

        assertEquals(
            RemoteAgentSettingsState(
                allowRead = true,
                allowOperate = false,
                allowSessions = true,
                allowWorkspaces = true,
                allowSuperAgent = true,
                allowLocalCrossWorkspace = true,
            ),
            updated,
        )
        assertEquals(updated, store.read())

        val persisted = JSONObject(File(dataDir, LocalRemoteAgentSettings.FILENAME).readText())
        assertEquals(true, persisted.getBoolean("allowRead"))
        assertEquals(false, persisted.getBoolean("allowOperate"))
        assertEquals(true, persisted.getBoolean("allowSessions"))
        assertEquals(true, persisted.getBoolean("allowWorkspaces"))
        assertEquals(true, persisted.getBoolean("allowSuperAgent"))
        assertEquals(true, persisted.getBoolean("allowLocalCrossWorkspace"))
        assertFalse(dataDir.listFiles().orEmpty().any { it.name.endsWith(".tmp") })
    }

    @Test
    fun readDefaultsOptionalFlagsAndRejectsNonBooleanOrUnknownFields() {
        val dataDir = File(tempDir, "linux/data").apply { mkdirs() }
        val file = File(dataDir, LocalRemoteAgentSettings.FILENAME)
        file.writeText("""{"allowRead":true,"allowOperate":false}""")
        val store = LocalRemoteAgentSettings.fromFilesDir(tempDir)
        assertEquals(
            RemoteAgentSettingsState(
                allowRead = true,
                allowOperate = false,
                allowSessions = false,
                allowWorkspaces = false,
                allowSuperAgent = false,
                allowLocalCrossWorkspace = false,
            ),
            store.read(),
        )

        file.writeText("""{"allowSuperAgent":true,"allowLocalCrossWorkspace":true}""")
        assertEquals(
            RemoteAgentSettingsState(
                allowRead = false,
                allowOperate = false,
                allowSessions = false,
                allowWorkspaces = false,
                allowSuperAgent = true,
                allowLocalCrossWorkspace = true,
            ),
            store.read(),
        )

        file.writeText("""{"allowRead":"true","allowOperate":false}""")
        assertThrows(IllegalArgumentException::class.java) { store.read() }

        file.writeText("""{"allowRead":true}""")
        assertThrows(IllegalArgumentException::class.java) { store.read() }

        file.writeText("""{"allowRead":true,"allowOperate":false,"extra":true}""")
        assertThrows(IllegalArgumentException::class.java) { store.read() }
    }
}
