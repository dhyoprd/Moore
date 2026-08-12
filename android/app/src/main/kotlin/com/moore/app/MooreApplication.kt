// Moore Android application entry (ticket #31 scaffold).
package com.moore.app

import android.app.Application
import com.moore.app.db.MooreDatabase
import com.moore.app.notify.RestEndNotifications

class MooreApplication : Application() {

    lateinit var database: MooreDatabase
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this
        database = MooreDatabase.build(this)
        // SC-cues BR-005: the rest_end notification channel exists before any
        // backgrounded rest expiry can dispatch.
        RestEndNotifications.ensureChannel(this)
    }

    companion object {
        lateinit var instance: MooreApplication
            private set
    }
}
