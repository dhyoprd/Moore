// Room database + migration chain (ticket #31).
// The SAME byte-identical .sql artifacts iOS applies via GRDB ship as Android
// assets and are executed verbatim, one Room version per migration file, in the
// chain order the Node verifiers use:
//   Room 1  = 0001_core.sql                 Room 6  = 0007_progression_full.sql
//   Room 2  = 0002_warmup_progression.sql   Room 7  = 0007_rest_fields.sql
//   Room 3  = 0003_import_columns.sql       Room 8  = 0008_personal_records.sql
//   Room 4  = 0005_routines_folders.sql     Room 9  = 0008_warmup_per_exercise_toggle.sql
//   Room 5  = 0006_routines_session_link.sql Room 10 = 0009_body_metrics.sql
// (0004_exercise_library.sql is NOT in the chain — it awaits the rewrite per
// docs/MIGRATION-INTEGRATION-NOTE.md, exactly as on iOS.)
package com.moore.app.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(
    entities = [
        FolderEntity::class,
        ExerciseEntity::class,
        RoutineEntity::class,
        PlannedSetEntity::class,
        WorkoutSessionEntity::class,
        CompletedSetEntity::class,
        PersonalRecordEntity::class,
        BodyMetricEntity::class,
        ProgressionSchemeEntity::class,
        AppSettingEntity::class,
        WarmupScaffoldEntity::class,
    ],
    version = MooreDatabase.VERSION,
    exportSchema = false,
)
abstract class MooreDatabase : RoomDatabase() {

    abstract fun folderDao(): FolderDao
    abstract fun routineDao(): RoutineDao
    abstract fun exerciseDao(): ExerciseDao
    abstract fun workoutSessionDao(): WorkoutSessionDao
    abstract fun personalRecordDao(): PersonalRecordDao
    abstract fun progressionDao(): ProgressionDao
    abstract fun appSettingDao(): AppSettingDao
    abstract fun warmupDao(): WarmupDao
    abstract fun analyticsDao(): AnalyticsDao

    companion object {
        const val VERSION = 10
        const val DB_NAME = "moore.sqlite"

        /// Migration identifier → asset file, in chain order (iOS numbering kept).
        val CHAIN: List<String> = listOf(
            "0001_core.sql",
            "0002_warmup_progression.sql",
            "0003_import_columns.sql",
            "0005_routines_folders.sql",
            "0006_routines_session_link.sql",
            "0007_progression_full.sql",
            "0007_rest_fields.sql",
            "0008_personal_records.sql",
            "0008_warmup_per_exercise_toggle.sql",
            "0009_body_metrics.sql",
        )

        /// Split a migration file into individual statements. SQLite `--`
        /// comments may contain semicolons (the shared migrations do), so
        /// comments are stripped with a string-aware scan before the split.
        fun splitStatements(sql: String): List<String> {
            val sb = StringBuilder()
            var i = 0
            var inString = false
            while (i < sql.length) {
                val c = sql[i]
                if (inString) {
                    sb.append(c)
                    if (c == '\'') {
                        if (i + 1 < sql.length && sql[i + 1] == '\'') {   // '' escape
                            sb.append('\'')
                            i += 2
                            continue
                        }
                        inString = false
                    }
                    i += 1
                    continue
                }
                if (c == '\'') {
                    inString = true
                    sb.append(c)
                    i += 1
                    continue
                }
                if (c == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
                    while (i < sql.length && sql[i] != '\n') i += 1
                    continue
                }
                sb.append(c)
                i += 1
            }
            return sb.toString().split(';')
                .map { it.trim() }
                .filter { it.isNotEmpty() }
        }

        private fun applyAsset(db: SupportSQLiteDatabase, context: Context, assetName: String) {
            val sql = context.assets.open("migrations/$assetName")
                .bufferedReader(Charsets.UTF_8).use { it.readText() }
            for (statement in splitStatements(sql)) {
                db.execSQL(statement)
            }
        }

        /// One Migration per .sql file, keyed by consecutive Room versions.
        fun migrations(context: Context): Array<Migration> {
            return CHAIN.mapIndexed { index, assetName ->
                val from = index + 1
                val to = index + 2
                object : Migration(from, to) {
                    override fun migrate(db: SupportSQLiteDatabase) {
                        applyAsset(db, context, assetName)
                    }
                }
            }.toTypedArray()
        }

        /// Fresh-install callback applies the chain from an empty database —
        /// Room creates nothing itself; the shared .sql IS the schema (AC:
        /// DB file layout matches iOS).
        fun build(context: Context): MooreDatabase {
            val appContext = context.applicationContext
            val callback = object : Callback() {
                override fun onCreate(db: SupportSQLiteDatabase) {
                    for (assetName in CHAIN) {
                        applyAsset(db, appContext, assetName)
                    }
                }
            }
            return Room.databaseBuilder(appContext, MooreDatabase::class.java, DB_NAME)
                .addCallback(callback)
                .addMigrations(*migrations(appContext))
                .fallbackToDestructiveMigration()
                .build()
        }
    }
}
