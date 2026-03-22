package com.example.projectphoenix

import android.animation.AnimatorSet
import android.animation.ObjectAnimator
import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.ImageView

class SplashActivity : Activity() {
  private var launchedMain = false
  private var splashAnimator: AnimatorSet? = null

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    setContentView(R.layout.activity_splash)

    val logo = findViewById<ImageView?>(R.id.splashPhoenix)
    if (logo != null) {
      startLogoAnimation(logo)
    }

    // Keep pre-splash short: native animation before Flutter bootstrap.
    window.decorView.postDelayed({ launchMainIfNeeded() }, 780L)
  }

  private fun startLogoAnimation(logo: View) {
    val alpha = ObjectAnimator.ofFloat(logo, View.ALPHA, 0.15f, 1f).apply {
      duration = 420L
      interpolator = AccelerateDecelerateInterpolator()
    }
    val scaleX = ObjectAnimator.ofFloat(logo, View.SCALE_X, 0.84f, 1.06f, 1f).apply {
      duration = 860L
      interpolator = AccelerateDecelerateInterpolator()
    }
    val scaleY = ObjectAnimator.ofFloat(logo, View.SCALE_Y, 0.84f, 1.04f, 1f).apply {
      duration = 860L
      interpolator = AccelerateDecelerateInterpolator()
    }
    val rise = ObjectAnimator.ofFloat(logo, View.TRANSLATION_Y, 18f, 0f).apply {
      duration = 760L
      interpolator = AccelerateDecelerateInterpolator()
    }

    splashAnimator = AnimatorSet().apply {
      playTogether(alpha, scaleX, scaleY, rise)
      start()
    }
  }

  private fun launchMainIfNeeded() {
    if (launchedMain || isFinishing || isDestroyed) return
    launchedMain = true

    startActivity(Intent(this, MainActivity::class.java))
    overridePendingTransition(android.R.anim.fade_in, android.R.anim.fade_out)
    finish()
  }

  override fun onDestroy() {
    splashAnimator?.cancel()
    splashAnimator = null
    super.onDestroy()
  }
}

