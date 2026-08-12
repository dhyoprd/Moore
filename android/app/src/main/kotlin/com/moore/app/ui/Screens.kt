// Compose scaffolds for the five screens per #31 SC-UI decisions:
// Home, Active Workout modal, History, Analytics, Settings.
// Layout only — every screen collects its ViewModel's StateFlow.
package com.moore.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.Divider
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.moore.app.R
import com.moore.foundation.SetStatus
import com.moore.settings.WeightUnit

// MARK: - Home (SC-routines §5)

@Composable
fun HomeScreen(viewModel: HomeViewModel, onStartEmpty: () -> Unit, onStartRoutine: () -> Unit) {
    val state by viewModel.state.collectAsState()
    Column(modifier = Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        state.streakCount?.let { streak ->
            // BR-005 streak chip (hidden when null / zero completed sessions).
            Card(modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = "$streak-day streak",
                    modifier = Modifier.padding(12.dp),
                    style = MaterialTheme.typography.labelLarge,
                )
            }
        }
        if (state.isEmpty) {
            // #14 empty-state keys (SettingsEngine.emptyStateCopy).
            Text(stringResource(R.string.home_empty_title), style = MaterialTheme.typography.headlineSmall)
            Text(stringResource(R.string.home_empty_sub), style = MaterialTheme.typography.bodyMedium)
            Button(onClick = onStartEmpty) { Text(stringResource(R.string.home_empty_cta)) }
            OutlinedButton(onClick = { }) { Text(stringResource(R.string.home_startEmpty_cta)) }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(state.routineNames) { name ->
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Row(
                            modifier = Modifier.padding(12.dp).fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(name, style = MaterialTheme.typography.titleMedium)
                            // Start CTA — one tap to start (BR-001).
                            Button(onClick = onStartRoutine) { Text("Start") }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Active Workout modal (SC-workout-logging §2 money screen)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ActiveWorkoutSheet(viewModel: ActiveWorkoutViewModel, onDismiss: () -> Unit) {
    val state by viewModel.state.collectAsState()
    if (!state.isModalVisible) return
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MaterialTheme.colorScheme.surfaceVariant) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.activeWorkout_title), style = MaterialTheme.typography.headlineSmall)
            val rows = viewModel.rows
            if (rows.isEmpty()) {
                Text(stringResource(R.string.activeWorkout_emptyList_line))
                OutlinedButton(onClick = { }) { Text(stringResource(R.string.activeWorkout_addExercise_cta)) }
            } else {
                LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    items(rows, key = { it.id }) { row ->
                        val statusMark = when (row.status) {
                            SetStatus.COMPLETED -> "✓"
                            SetStatus.FAILED -> "✗"
                            SetStatus.DROPPED -> "—"
                            else -> "○"
                        }
                        Card(modifier = Modifier.fillMaxWidth()) {
                            Row(
                                modifier = Modifier.padding(12.dp).fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                            ) {
                                Text("$statusMark  ${row.exerciseId}")
                                val planned = listOfNotNull(
                                    row.plannedWeight?.let { "${it}kg" },
                                    row.plannedReps?.let { "×$it" },
                                ).joinToString(" ")
                                Text(planned.ifEmpty { "—" })
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - History (SC-analytics BR-006)

@Composable
fun HistoryScreen(viewModel: HistoryViewModel) {
    val state by viewModel.state.collectAsState()
    Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        if (state.isEmpty) {
            Text(stringResource(R.string.history_empty_title), style = MaterialTheme.typography.headlineSmall)
            Text(stringResource(R.string.history_empty_sub), style = MaterialTheme.typography.bodyMedium)
            Button(onClick = { }) { Text(stringResource(R.string.history_empty_cta)) }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                state.months.forEach { month ->
                    item(key = month.month) {
                        Text(month.month, style = MaterialTheme.typography.titleMedium)
                    }
                    items(month.rows, key = { it.sessionId }) { row ->
                        Card(modifier = Modifier.fillMaxWidth()) {
                            Column(modifier = Modifier.padding(12.dp)) {
                                Text(row.name ?: row.day)
                                Text(
                                    "${row.completedCount} sets · ${row.tonnage} kg" +
                                        if (row.prCount > 0) " · PR" else "",
                                    style = MaterialTheme.typography.bodySmall,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Analytics (SC-analytics §5)

@Composable
fun AnalyticsScreen(viewModel: AnalyticsViewModel) {
    val state by viewModel.state.collectAsState()
    Column(modifier = Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (state.isEmpty) {
            Text(stringResource(R.string.analytics_empty_title), style = MaterialTheme.typography.headlineSmall)
            Text(stringResource(R.string.analytics_empty_sub), style = MaterialTheme.typography.bodyMedium)
            Button(onClick = { }) { Text(stringResource(R.string.analytics_empty_cta)) }
        } else {
            // Adherence header (BR-001/BR-010).
            Card(modifier = Modifier.fillMaxWidth()) {
                Row(modifier = Modifier.padding(12.dp).fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("7d: ${state.header.sessionsLast7}")
                    Text("30d: ${state.header.sessionsLast30}")
                    Text("Streak: ${state.header.currentStreak}")
                }
            }
            // Weekly tonnage (BR-003).
            Text("Weekly tonnage", style = MaterialTheme.typography.titleMedium)
            LazyColumn {
                items(state.weeklyTonnage) { week ->
                    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(week.week)
                        Text("${week.tonnage} kg")
                    }
                }
            }
            Divider()
            // Muscle split (BR-004).
            Text("Muscle split", style = MaterialTheme.typography.titleMedium)
            state.muscleSplit.forEach { bucket ->
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(bucket.bucket)
                    Text("${bucket.tonnage} kg (${bucket.pct}%)")
                }
            }
        }
    }
}

// MARK: - Settings (SC-settings §5)

@Composable
fun SettingsScreen(viewModel: SettingsViewModel) {
    val state by viewModel.state.collectAsState()
    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        contentPadding = PaddingValues(bottom = 16.dp),
    ) {
        item {
            Text(stringResource(R.string.settings_title), style = MaterialTheme.typography.headlineSmall)
        }
        // Units (BR-001/BR-004: display-only toggle, never rewrites data).
        item {
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.settings_units_title), style = MaterialTheme.typography.titleMedium)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                        Text(stringResource(R.string.settings_units_weight))
                        Switch(
                            checked = state.settings.weightUnit == WeightUnit.LB,
                            onCheckedChange = { lb ->
                                viewModel.setWeightUnit(if (lb) WeightUnit.LB else WeightUnit.KG)
                            },
                        )
                    }
                    Text("Unit: ${state.settings.weightUnit.raw}")
                }
            }
        }
        // Rest defaults (BR-005).
        item {
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(12.dp)) {
                    Text(stringResource(R.string.settings_restDefaults_title), style = MaterialTheme.typography.titleMedium)
                    Text("Compound: ${state.settings.defaultRestCompoundSec}s")
                    Text("Isolation: ${state.settings.defaultRestIsolationSec}s")
                }
            }
        }
        // Body metrics (BR-006/BR-007).
        item {
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(12.dp)) {
                    Text(stringResource(R.string.settings_bodyMetrics_title), style = MaterialTheme.typography.titleMedium)
                    OutlinedButton(onClick = { }) { Text("Add entry") }
                }
            }
        }
        // Data & sync (BR-008/BR-012).
        item {
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.settings_dataSync_title), style = MaterialTheme.typography.titleMedium)
                    Button(onClick = { }) { Text(stringResource(R.string.settings_dataSync_exportCta)) }
                    // SAF-export of the SQLite file with identical filename format
                    // (SettingsEngine.backupFileName) lands on the Android side here.
                    OutlinedButton(onClick = { }) { Text(stringResource(R.string.settings_dataSync_importHevy)) }
                }
            }
        }
        // Cloud sync (BR-011: permanently greyed at v1).
        item {
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(12.dp)) {
                    Text(stringResource(R.string.settings_cloudSync_title), style = MaterialTheme.typography.titleMedium)
                    Text(stringResource(R.string.settings_cloudSync_coming), style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        // Tombstones (BR-010).
        item {
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(12.dp)) {
                    Text(stringResource(R.string.settings_tombstones_title), style = MaterialTheme.typography.titleMedium)
                    Text("Nothing deleted")
                }
            }
        }
    }
}
