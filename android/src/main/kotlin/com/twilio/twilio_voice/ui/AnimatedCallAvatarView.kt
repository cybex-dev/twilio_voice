package com.twilio.twilio_voice.ui

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.View
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * Custom view that displays an animated rotating border ring around a center content,
 * similar to the Dart ActiveCallAnimatedWidget
 */
class AnimatedCallAvatarView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private var rotationAngle = 0f
    private var animator: ValueAnimator? = null
    private var isCallConnected = false

    private val animatingBorderPaint = Paint().apply {
        isAntiAlias = true
        style = Paint.Style.STROKE
        strokeWidth = 2f
        color = Color.parseColor("#1b6cf7")
        strokeCap = Paint.Cap.ROUND
    }

    private val trackPaint = Paint().apply {
        isAntiAlias = true
        style = Paint.Style.STROKE
        strokeWidth = 1f
        color = Color.parseColor("#4D1b6cf7") // 30% opacity
    }

    init {
        if (!isCallConnected) {
            startAnimation()
        }
    }

    private fun startAnimation() {
        animator = ValueAnimator.ofFloat(0f, (2 * PI).toFloat()).apply {
            duration = 600
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.RESTART
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
        val radius = (width / 2f) * 0.8f

        // Draw track circle
        canvas.drawCircle(centerX, centerY, radius, trackPaint)

        if (!isCallConnected) {
            // Draw animated segments
            val segmentPaint = Paint().apply {
                isAntiAlias = true
                style = Paint.Style.STROKE
                strokeWidth = 3f
                color = Color.parseColor("#1b6cf7")
                strokeCap = Paint.Cap.ROUND
            }

            val sweepAngle = PI / 3 // 60 degrees

            // Draw first segment
            drawArcSegment(canvas, centerX, centerY, radius, rotationAngle, sweepAngle.toFloat(), segmentPaint)

            // Draw second segment opposite
            drawArcSegment(canvas, centerX, centerY, radius, rotationAngle + PI.toFloat(), sweepAngle.toFloat(), segmentPaint)
        }
    }

    private fun drawArcSegment(
        canvas: Canvas,
        centerX: Float,
        centerY: Float,
        radius: Float,
        startAngle: Float,
        sweepAngle: Float,
        paint: Paint
    ) {
        val path = android.graphics.Path()
        val segments = 50 // Smoothness of the arc
        
        for (i in 0..segments) {
            val angle = startAngle + (sweepAngle * i / segments)
            val x = centerX + radius * cos(angle)
            val y = centerY + radius * sin(angle)

            if (i == 0) {
                path.moveTo(x, y)
            } else {
                path.lineTo(x, y)
            }
        }

        canvas.drawPath(path, paint)
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        animator?.cancel()
    }
}
