package com.twilio.twilio_voice;

import android.Manifest;
import android.app.KeyguardManager;
import android.app.NotificationManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.media.AudioManager;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.util.Log;
import android.view.View;
import android.view.WindowManager;
import android.widget.ImageView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.Lifecycle;
import androidx.lifecycle.ProcessLifecycleOwner;
import androidx.localbroadcastmanager.content.LocalBroadcastManager;

//import com.twilio.voice.Call;
import com.twilio.voice.CallInvite;

public class BackgroundCallJavaActivity extends AppCompatActivity{

    private static String TAG = "BackgroundCallActivity";
    public static final String TwilioPreferences = "mx.TwilioPreferences";


//    private Call activeCall;
    private NotificationManager notificationManager;

    private PowerManager.WakeLock wakeLock;

    private TextView tvUserName;
    private TextView tvCallStatus;
    private ImageView btnMute;
    private ImageView btnOutput;
    private ImageView btnHangUp;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_background_call);

        tvUserName = (TextView) findViewById(R.id.tvUserName) ;
        tvCallStatus = (TextView) findViewById(R.id.tvCallStatus) ;
        btnMute = (ImageView) findViewById(R.id.btnMute);
        btnOutput = (ImageView) findViewById(R.id.btnOutput);
        btnHangUp = (ImageView) findViewById(R.id.btnHangUp);

        KeyguardManager kgm = (KeyguardManager) getSystemService(Context.KEYGUARD_SERVICE);
        Boolean isKeyguardUp = kgm.inKeyguardRestrictedInputMode();

        Log.d(TAG, "isKeyguardUp $isKeyguardUp");
        if (isKeyguardUp) {

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                Log.d(TAG, "ohh shiny phone!");
                setTurnScreenOn(true);
                setShowWhenLocked(true);
                kgm.requestDismissKeyguard(this, null);

            }else{
                Log.d(TAG, "diego's old phone!");
                PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
                wakeLock = pm.newWakeLock(PowerManager.FULL_WAKE_LOCK, TAG);
                wakeLock.acquire();

                getWindow().addFlags(
                        WindowManager.LayoutParams.FLAG_FULLSCREEN |
                        WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD |
                        WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED |
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                );
            }
        }

        notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);

        handleCallIntent(getIntent());
    }

    private void handleCallIntent(Intent intent){
        if (intent != null){

            String fromId = intent.getStringExtra(Constants.CALL_FROM).replace("client:","");
            if(fromId != null){

                SharedPreferences preferences = getApplicationContext().getSharedPreferences(TwilioPreferences, Context.MODE_PRIVATE);
                String caller = preferences.getString(fromId, preferences.getString("defaultCaller", "Desconocido"));
                Log.d(TAG,"handleCallIntent");
                Log.d(TAG,"caller from");
                Log.d(TAG,caller);

                tvUserName.setText(caller);
                tvCallStatus.setText("Conectado");
                Log.d(TAG, "handleCallIntent-");
                configCallUI();
            }
        }
    }



    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (intent != null && intent.getAction() != null){
        Log.d(TAG, "onNewIntent-");
        Log.d(TAG, intent.getAction());
            switch (intent.getAction()){
                case Constants.ACTION_CANCEL_CALL:
                    callCanceled();
                    break;
                default: {
                }
            }
        }
    }


    boolean isMuted = false;
    private void configCallUI() {
        Log.d(TAG, "configCallUI");

            btnMute.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    Log.d(TAG, "onCLick");
                    sendIntent(Constants.ACTION_TOGGLE_MUTE);
                    isMuted = !isMuted;
                    applyFabState(btnMute, isMuted);
                }
            });

            btnHangUp.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    sendIntent(Constants.ACTION_END_CALL);
                    finish();
                }
            });
            btnOutput.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    AudioManager audioManager = (AudioManager) getApplicationContext().getSystemService(Context.AUDIO_SERVICE);
                    boolean isOnSpeaker = !audioManager.isSpeakerphoneOn();
                    audioManager.setSpeakerphoneOn(isOnSpeaker);
                    applyFabState(btnOutput, isOnSpeaker);
                }
            });

    }

    private void applyFabState(ImageView button, Boolean enabled) {
        // Set fab as pressed when call is on hold

        ColorStateList colorStateList;

        if(enabled){
            colorStateList = ColorStateList.valueOf(ContextCompat.getColor(this, R.color.white_55));
        }else{
            colorStateList = ColorStateList.valueOf(ContextCompat.getColor(this, R.color.accent));
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            button.setBackgroundTintList(colorStateList);
        }
    }

    private void sendIntent(String action){
        Log.d(TAG,"Sending intent");
        Log.d(TAG,action);
        Intent activeCallIntent = new Intent();
        activeCallIntent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        activeCallIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        activeCallIntent.setAction(action);
        LocalBroadcastManager.getInstance(this).sendBroadcast(activeCallIntent);
    }


    private void callCanceled(){
        finish();
    }



    private Boolean isAppVisible(){
        return ProcessLifecycleOwner
                .get()
                .getLifecycle()
                .getCurrentState()
                .isAtLeast(Lifecycle.State.STARTED);
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (wakeLock != null){
            wakeLock.release();
        }
    }

}