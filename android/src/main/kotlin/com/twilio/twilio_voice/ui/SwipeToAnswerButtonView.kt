package com.twilio.twilio_voice.ui

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import android.view.animation.DecelerateInterpolator
import kotlin.math.abs

/**
 * Custom swipeable button for accepting/declining incoming calls
 * Similar to the Dart SwipeToAnswerButton with drag gesture detection
 */
class SwipeToAnswerButtonView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private val baseRadius = 35f
    private val maxRadius = 70f
    private val dragThreshold = 100f
    
    private var dragDistance = 0f
    private var isAccepted = false
    
    private lateinit var backgroundColor: android.graphics.Color
    private var onAnswerListener: (() -> Unit)? = null
    
    private val buttonPaint = Paint().apply {
        isAntiAlias = true
        style = Paint.Style.FILL
    }
    
    private val pulsePaint = Paint().apply {
        isAntiAlias = true
        style = Paint.Style.FILL
        color = Color.parseColor("#1b6cf726") // Semi-transparent primary
    }
    
    private val resetAnimator = ValueAnimator.ofFloat(0f, 0f).apply {
        duration = 300
        interpolator = DecelerateInterpolator()
        addUpdateListener { animator ->
            dragDistance = animator.animatedValue as Float
            invalidate()
        }
    }
    
    private val pulseAnimator = ValueAnimator.ofFloat(1f, 1.4f).apply {
        duration = 1500
        repeatCount = ValueAnimator.INFINITE
        addUpdateListener {
            invalidate()
        }
    }
    
    init {
        pulseAnimator.start()
    }
    
    fun setOnAnswerListener(listener: () -> Unit) {
        onAnswerListener = listener
    }
    
    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.action) {
            MotionEvent.ACTION_MOVE -> {
                if (!isAccepted) {
                    val delta = event.y
                    dragDistance = abs(delta).coerceAtMost(dragThreshold)
                    
                    if (dragDistance >= dragThreshold) {
                        isAccepted = true
                        pulseAnimator.cancel()
                        onAnswerListener?.invoke()
                    }
                    invalidate()
                }
                return true
            }
            MotionEvent.ACTION_UP,
            MotionEvent.ACTION_CANCEL -> {
                if (!isAccepted) {
                    resetToCenter()
                }
                return true
            }
        }
        return super.onTouchEvent(event)
    }
    
    private fun resetToCenter() {
        resetAnimator.setFloatValues(dragDistance, 0f)
        resetAnimator.start()
    }
    
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        
        val centerX = width.toFloat() / 2f
        val centerY = height.toFloat() / 2f
        
        if (!isAccepted) {
            // Draw pulse effect
            val pulseValue = (pulseAnimator.animatedValue as Float) ?: 1f
            val pulseRadius = baseRadius * pulseValue
            val pulseOpacity = (1.0f - ((pulseValue - 1f) / 0.4f)).coerceIn(0f, 1f)
            pulsePaint.alpha = (pulseOpacity * 255).toInt()
            canvas.drawCircle(centerX, centerY, pulseRadius, pulsePaint)
        }
        
        // Draw main button circle
        val percentage = (dragDistance / dragThreshold).coerceIn(0f, 1f)
        buttonPaint.color = Color.parseColor("#4CAF50") // Green for accept
        canvas.drawCircle(centerX, centerY, baseRadius, buttonPaint)
        
        // Draw overlay when dragging
        if (percentage > 0 && !isAccepted) {
            val overlayPaint = Paint().apply {
                isAntiAlias = true
                style = Paint.Style.FILL
                color = Color.parseColor("#1b6cf7")
                alpha = (percentage * 100).toInt()
            }
            val overlayRadius = baseRadius + (maxRadius - baseRadius) * percentage
            canvas.drawCircle(centerX, centerY, overlayRadius, overlayPaint)
        }
    }
    
    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        pulseAnimator.cancel()
        resetAnimator.cancel()
    }
}
