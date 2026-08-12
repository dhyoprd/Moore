// ViewModels for the five screens (#31 SC-UI decisions: Home, Active Workout
// modal, History, Analytics, Settings). Layout-only scaffolds bound to
// StateFlow — @Observable ↔ ViewModel + StateFlow per the #31 naming map.
package com.moore.app.ui

import androidx.lifecycle.ViewModel
import com.moore.analytics.AdherenceHeader
import com.moore.analytics.HistoryMonth
import com.moore.analytics.MuscleBucket
import com.moore.analytics.TrendPoint
import com.moore.analytics.WeekTonnage
import com.moore.foundation.SetStatus
import com.moore.settings.AppSettingsSnapshot
import com.moore.settings.WeightUnit
import com.moore.workout.SetSnapshot
import com.moore.workout.StateSnapshot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

// MARK: - Home (SC-routines §5)

data class HomeUiState(
    val routineNames: List<String> = emptyList(),
    val streakCount: Int? = null,
    val activeSessionPresent: Boolean = false,
    val isEmpty: Boolean = true,
)

class HomeViewModel : ViewModel() {
    private val _state = MutableStateFlow(HomeUiState())
    val state: StateFlow<HomeUiState> = _state.asStateFlow()

    /// Scaffold seam: the DAO-backed readModel() populates the StateFlow.
    fun loadFrom(rows: List<com.moore.routines.RoutineRow>, streak: Int?, activeSession: Boolean) {
        _state.value = HomeUiState(
            routineNames = rows.map { it.routine.name },
            streakCount = streak,
            activeSessionPresent = activeSession,
            isEmpty = rows.isEmpty(),
        )
    }
}

// MARK: - Active Workout modal (SC-workout-logging §2)

data class ActiveWorkoutUiState(
    val snapshot: StateSnapshot? = null,
    val isModalVisible: Boolean = false,
)

class ActiveWorkoutViewModel : ViewModel() {
    private val _state = MutableStateFlow(ActiveWorkoutUiState())
    val state: StateFlow<ActiveWorkoutUiState> = _state.asStateFlow()

    /// Scaffold seam: bind a cold-rendered StateSnapshot (FSM read model).
    fun bind(snapshot: StateSnapshot?) {
        _state.value = ActiveWorkoutUiState(snapshot = snapshot, isModalVisible = snapshot != null)
    }

    val rows: List<SetSnapshot> get() = _state.value.snapshot?.sets ?: emptyList()

    fun nextIncompleteRow(): SetSnapshot? {
        val nextId = _state.value.snapshot?.nextIncompleteSetId ?: return null
        return rows.firstOrNull { it.id == nextId }
    }

    fun isRowActionable(row: SetSnapshot): Boolean = row.status == SetStatus.PLANNED
}

// MARK: - History (SC-analytics BR-006)

data class HistoryUiState(
    val months: List<HistoryMonth> = emptyList(),
    val isEmpty: Boolean = true,
)

class HistoryViewModel : ViewModel() {
    private val _state = MutableStateFlow(HistoryUiState())
    val state: StateFlow<HistoryUiState> = _state.asStateFlow()

    fun bind(months: List<HistoryMonth>) {
        _state.value = HistoryUiState(months = months, isEmpty = months.isEmpty())
    }
}

// MARK: - Analytics (SC-analytics §5)

data class AnalyticsUiState(
    val header: AdherenceHeader = AdherenceHeader(0, 0, 0),
    val trend: List<TrendPoint> = emptyList(),
    val weeklyTonnage: List<WeekTonnage> = emptyList(),
    val muscleSplit: List<MuscleBucket> = emptyList(),
    val isEmpty: Boolean = true,
)

class AnalyticsViewModel : ViewModel() {
    private val _state = MutableStateFlow(AnalyticsUiState())
    val state: StateFlow<AnalyticsUiState> = _state.asStateFlow()

    fun bind(
        header: AdherenceHeader,
        trend: List<TrendPoint>,
        weeklyTonnage: List<WeekTonnage>,
        muscleSplit: List<MuscleBucket>,
    ) {
        _state.value = AnalyticsUiState(
            header = header,
            trend = trend,
            weeklyTonnage = weeklyTonnage,
            muscleSplit = muscleSplit,
            isEmpty = trend.isEmpty() && weeklyTonnage.isEmpty(),
        )
    }
}

// MARK: - Settings (SC-settings §5)

data class SettingsUiState(
    val settings: AppSettingsSnapshot = AppSettingsSnapshot.DEFAULT,
    val cloudSyncGreyed: Boolean = true,
    val hevyImportBlocked: Boolean = true,
    val backupFileNamePreview: String = "",
)

class SettingsViewModel : ViewModel() {
    private val _state = MutableStateFlow(SettingsUiState())
    val state: StateFlow<SettingsUiState> = _state.asStateFlow()

    fun bind(settings: AppSettingsSnapshot) {
        _state.value = _state.value.copy(settings = settings)
    }

    /// BR-001: the ONLY write — toggles the display unit, never the data.
    fun setWeightUnit(unit: WeightUnit) {
        val current = _state.value.settings
        _state.value = _state.value.copy(
            settings = current.copy(weightUnit = unit),
        )
    }
}
