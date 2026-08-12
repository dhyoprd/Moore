// Moore Android scaffold shell (ticket #31): bottom-nav over the five surfaces —
// Home, Active Workout modal, History, Analytics, Settings.
package com.moore.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.viewmodel.compose.viewModel
import com.moore.app.ui.ActiveWorkoutSheet
import com.moore.app.ui.ActiveWorkoutViewModel
import com.moore.app.ui.AnalyticsScreen
import com.moore.app.ui.AnalyticsViewModel
import com.moore.app.ui.HistoryScreen
import com.moore.app.ui.HistoryViewModel
import com.moore.app.ui.HomeScreen
import com.moore.app.ui.HomeViewModel
import com.moore.app.ui.MooreTheme
import com.moore.app.ui.SettingsScreen
import com.moore.app.ui.SettingsViewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MooreTheme {
                MooreShell()
            }
        }
    }
}

private data class Tab(val titleRes: Int, val icon: ImageVector)

@Composable
private fun MooreShell() {
    val tabs = listOf(
        Tab(R.string.tab_home, Icons.Filled.Home),
        Tab(R.string.tab_history, Icons.Filled.DateRange),
        Tab(R.string.tab_analytics, Icons.Filled.Info),
        Tab(R.string.tab_settings, Icons.Filled.Settings),
    )
    var selected by rememberSaveable { mutableIntStateOf(0) }
    var workoutSheetOpen by rememberSaveable { mutableStateOf(false) }

    val homeViewModel: HomeViewModel = viewModel()
    val workoutViewModel: ActiveWorkoutViewModel = viewModel()
    val historyViewModel: HistoryViewModel = viewModel()
    val analyticsViewModel: AnalyticsViewModel = viewModel()
    val settingsViewModel: SettingsViewModel = viewModel()

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        bottomBar = {
            NavigationBar {
                tabs.forEachIndexed { index, tab ->
                    NavigationBarItem(
                        selected = selected == index,
                        onClick = { selected = index },
                        icon = { Icon(tab.icon, contentDescription = null) },
                        label = { Text(stringResource(tab.titleRes)) },
                    )
                }
            }
        },
    ) { innerPadding ->
        Box(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
            when (selected) {
                0 -> HomeScreen(
                    viewModel = homeViewModel,
                    onStartEmpty = { workoutSheetOpen = true },
                    onStartRoutine = { workoutSheetOpen = true },
                )
                1 -> HistoryScreen(viewModel = historyViewModel)
                2 -> AnalyticsScreen(viewModel = analyticsViewModel)
                3 -> SettingsScreen(viewModel = settingsViewModel)
            }
            // The Active Workout money screen is a modal over Home (SC-workout-logging §2).
            if (workoutSheetOpen) {
                ActiveWorkoutSheet(viewModel = workoutViewModel, onDismiss = { workoutSheetOpen = false })
            }
        }
    }
}
