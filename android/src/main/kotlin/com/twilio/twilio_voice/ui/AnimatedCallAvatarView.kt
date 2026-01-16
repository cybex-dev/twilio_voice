package com.twilio.twilio_voice.ui

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
import kotlin.math.PI

/**
 * Custom view that displays an animated rotating border ring around a center content,
 * similar to the iOS design with a cleaner ring effect
 */
class AnimatedCallAvatarView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private var rotationAngle = 0f
    private var animator: ValueAnimator? = null
    private var isCallConnected = false

    // Dark ring track (background) - solid blue ring outline
    private val trackPaint = Paint().apply {
        isAntiAlias = true
        style = Paint.Style.STROKE
        strokeWidth = 2f
        color = Color.parseColor("#346299") // Solid blue ring
    }

    // Glow paint for the ring track (subtle outer glow)
    private val trackGlowPaint = Paint().apply {
        isAntiAlias = true
        style = Paint.Style.STROKE
        strokeWidth = 6f
        color = Color.parseColor("#40346299") // Transparent blue glow
        maskFilter = BlurMaskFilter(8f, BlurMaskFilter.Blur.NORMAL)
    }

    // Animated segment paint (brighter part for subtle animation)
    private val segmentPaint = Paint().apply {
        isAntiAlias = true
        style = Paint.Style.STROKE
        strokeWidth = 3f
        color = Color.parseColor("#7AAEE0") // Lighter blue for highlight
        strokeCap = Paint.Cap.ROUND
    }

    // Glow paint for the animated segment (stronger glow)
    private val segmentGlowPaint = Paint().apply {
        isAntiAlias = true
        style = Paint.Style.STROKE
        strokeWidth = 12f
        color = Color.parseColor("#807AAEE0") // Bright blue with transparency
        strokeCap = Paint.Cap.ROUND
        maskFilter = BlurMaskFilter(16f, BlurMaskFilter.Blur.NORMAL)
    }

    // Outer glow for the segment (creates halo effect)
    private val segmentOuterGlowPaint = Paint().apply {
        isAntiAlias = true
        style = Paint.Style.STROKE
        strokeWidth = 20f
        color = Color.parseColor("#407AAEE0") // More transparent for outer glow
        strokeCap = Paint.Cap.ROUND
        maskFilter = BlurMaskFilter(24f, BlurMaskFilter.Blur.OUTER)
    }

    init {
        // Required for blur mask filter to work
        setLayerType(LAYER_TYPE_SOFTWARE, null)
        
        if (!isCallConnected) {
            startAnimation()
        }
    }

    private fun startAnimation() {
        animator = ValueAnimator.ofFloat(0f, 360f).apply {
            duration = 2500 // Even slower rotation
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.RESTART
            interpolator = android.view.animation.LinearInterpolator()
            addUpdateListener { animator ->
                rotationAngle = animator.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    fun setCallConnected(connected: Boolean) {
        isCallConnected = connected
        if (connected) {
            animator?.cancel()
            animator = null
        } else {
            if (animator == null) {
                startAnimation()
            }
        }
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val centerX = width / 2f
        val centerY = height / 2f
        val strokeWidth = 3f
        val radius = (width / 2f) - (strokeWidth / 2f) - 12f // More padding for glow

        val rect = RectF(
            centerX - radius,
            centerY - radius,
            centerX + radius,
            centerY + radius
        )

        // Draw track glow (subtle ambient glow)
        canvas.drawCircle(centerX, centerY, radius, trackGlowPaint)
        
        // Draw full track circle (dark background ring)
        canvas.drawCircle(centerX, centerY, radius, trackPaint)

        if (!isCallConnected) {
            // Draw animated arc segment with glow effects
            val sweepAngle = 90f // 90 degree arc
            
            // Draw outer glow first (creates halo)
            canvas.drawArc(rect, rotationAngle - 90f, sweepAngle, false, segmentOuterGlowPaint)
            
            // Draw inner glow
            canvas.drawArc(rect, rotationAngle - 90f, sweepAngle, false, segmentGlowPaint)
            
            // Draw solid segment on top
            canvas.drawArc(rect, rotationAngle - 90f, sweepAngle, false, segmentPaint)
        }
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        animator?.cancel()
    }
}
