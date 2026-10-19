package tv.velvet

import android.app.Application
import tv.velvet.di.AppContainer

class VelvetApp : Application() {
    // A signed launcher can bind the provider before Application.onCreate finishes.
    // Share one thread-safe graph across provider-first and activity-first startup.
    val container: AppContainer by lazy(LazyThreadSafetyMode.SYNCHRONIZED) { AppContainer(this) }

    override fun onCreate() {
        super.onCreate()
        container // Preserve normal eager startup; a provider may already have created it.
    }
}
