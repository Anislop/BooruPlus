package com.booruplus.app

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException
import java.util.UUID

/**
 * Serves media saved for the share sheet, and a downloaded update for the
 * package installer, from the app's private `cache/shared` folder, read-only.
 * Each file sits in its own randomly named folder, which is part of its URI.
 * It is not exported: receiving apps read a file only through the temporary
 * grant on the intent.
 */
class SharedMediaProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    private fun fileFor(uri: Uri): File? {
        val segments = uri.pathSegments
        if (segments.size != 2) return null
        val (token, name) = segments
        if (!TOKEN.matches(token) || name.isEmpty() || name.startsWith(".") ||
            name.contains('/') || name.contains('\\')) return null
        val context = context ?: return null
        val folder = File(File(context.cacheDir, DIRECTORY).canonicalFile, token)
        val file = File(folder, name).canonicalFile
        return if (file.parentFile == folder && file.isFile) file else null
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("Shared media is read-only")
        val file = fileFor(uri) ?: throw FileNotFoundException()
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String? = fileFor(uri)?.let { mediaMimeType(it.name) }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? {
        val file = fileFor(uri) ?: return null
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns, 1).apply {
            addRow(columns.map { column ->
                when (column) {
                    OpenableColumns.DISPLAY_NAME -> file.name
                    OpenableColumns.SIZE -> file.length()
                    else -> null
                }
            })
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    companion object {
        const val DIRECTORY = "shared"
        private val TOKEN = Regex("^[0-9a-f]{32}$")

        /** A random folder name for one shared file. */
        fun newToken(): String = UUID.randomUUID().toString().replace("-", "")

        /** The URI of [file], kept in a [newToken] folder of [DIRECTORY]. */
        fun uriFor(context: Context, file: File): Uri = Uri.Builder()
            .scheme("content")
            .authority("${context.packageName}.shared")
            .appendPath(file.parentFile?.name.orEmpty())
            .appendPath(file.name)
            .build()
    }
}
