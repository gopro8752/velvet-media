package tv.velour

import android.app.Application
import android.content.Context
import tv.velour.data.apps.AppRepository
import tv.velour.data.settings.SettingsRepository
import tv.velour.data.weather.WeatherRepository
import tv.velour.data.velvet.VelvetRepository

class VelourApp : Application() {
    val container: AppContainer by lazy { AppContainer(this) }

    override fun onCreate() {
        super.onCreate()
        // Kick the package scan before any UI composes; start() is idempotent, so the
        // belt-and-suspenders call in HomeViewModel.init is a no-op after this.
        container.appRepository.start()
    }
}

class AppContainer(context: Context) {
    val appRepository: AppRepository = AppRepository(context)
    val settingsRepository: SettingsRepository = SettingsRepository(context)
    val weatherRepository: WeatherRepository = WeatherRepository()
    val velvetRepository: VelvetRepository = VelvetRepository(context)
}
