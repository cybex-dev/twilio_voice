package com.twilio.twilio_voice;

import android.app.KeyguardManager;
import android.app.NotificationManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
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

import androidx.appcompat.app.AppCompatActivity;
import androidx.core.content.ContextCompat;
import androidx.localbroadcastmanager.content.LocalBroadcastManager;

import com.google.android.material.bottomsheet.BottomSheetDialog;

public class BackgroundCallJavaActivity extends AppCompatActivity {

    private static String TAG = "BackgroundCallActivity";
    public static final String TwilioPreferences = "com.twilio.twilio_voicePreferences";


    //    private Call activeCall;
    private NotificationManager notificationManager;

    private PowerManager powerManager;
    private PowerManager.WakeLock wakeLock;

    private TextView tvUserName;
    private TextView tvCallStatus;
    private ImageView btnMute;
    private ImageView btnOutput;
    private ImageView btnHangUp;
    private ImageView btnKeypad;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_background_call);
        powerManager = (PowerManager) getSystemService(Context.POWER_SERVICE);

        tvUserName = (TextView) findViewById(R.id.tvUserName);
        tvCallStatus = (TextView) findViewById(R.id.tvCallStatus);
        btnMute = (ImageView) findViewById(R.id.btnMute);
        btnOutput = (ImageView) findViewById(R.id.btnOutput);
        btnHangUp = (ImageView) findViewById(R.id.btnHangUp);
        btnKeypad = (ImageView) findViewById(R.id.btnKeypad);

        KeyguardManager kgm = (KeyguardManager) getSystemService(Context.KEYGUARD_SERVICE);
        Boolean isKeyguardUp = kgm.inKeyguardRestrictedInputMode();

        Log.d(TAG, "isKeyguardUp $isKeyguardUp");
        if (isKeyguardUp) {

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setTurnScreenOn(true);
                setShowWhenLocked(true);
                kgm.requestDismissKeyguard(this, null);

            } else {
                wakeLock = powerManager.newWakeLock(PowerManager.FULL_WAKE_LOCK, TAG);
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

    private void handleCallIntent(Intent intent) {
        if (intent != null) {


            if (intent.getStringExtra(Constants.CALL_FROM) != null) {
                activateSensor();
                String fromId = intent.getStringExtra(Constants.CALL_FROM).replace("client:", "");

                SharedPreferences preferences = getApplicationContext().getSharedPreferences(TwilioPreferences, Context.MODE_PRIVATE);
                String caller = preferences.getString(fromId, preferences.getString("defaultCaller", getString(R.string.unknown_caller)));
                Log.d(TAG, "handleCallIntent");
                Log.d(TAG, "caller from");
                Log.d(TAG, caller);

                tvUserName.setText(caller);
                tvCallStatus.setText(getString(R.string.connected_status));
                Log.d(TAG, "handleCallIntent-");
                configCallUI();
            } else {
                finish();
            }
        }
    }

    private void activateSensor() {
        if (wakeLock == null) {
            Log.d(TAG, "New wakeLog");
            wakeLock = powerManager.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "incall");
        }
        if (!wakeLock.isHeld()) {
            Log.d(TAG, "wakeLog acquire");
            wakeLock.acquire();
        }
    }

    private void deactivateSensor() {
        if (wakeLock != null && wakeLock.isHeld()) {
            Log.d(TAG, "wakeLog release");
            wakeLock.release();
        }
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (intent != null && intent.getAction() != null) {
            Log.d(TAG, "onNewIntent-");
            Log.d(TAG, intent.getAction());
            switch (intent.getAction()) {
                case Constants.ACTION_CANCEL_CALL:
                    callCanceled();
                    break;
                default: {
                }
            }
        }
    }


    boolean isMuted = false;
    boolean isKeypadOpen = false;

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

        btnKeypad.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                Log.d(TAG, "onCLick");
//                sendIntent(Constants.ACTION_TOGGLE_KEYPAD);
                BottomSheetDialog keypadBottomSheetDialog = new BottomSheetDialog(BackgroundCallJavaActivity.this);
                keypadBottomSheetDialog.setContentView(R.layout.keypad_bottom_sheet);

                TextView keypadView = keypadBottomSheetDialog.findViewById(R.id.txtKeypad);
                ImageView btnBackSpace = keypadBottomSheetDialog.findViewById(R.id.btnBackSpace);
                TextView btn0 = keypadBottomSheetDialog.findViewById(R.id.NUMBER_0);
                TextView btn1 = keypadBottomSheetDialog.findViewById(R.id.NUMBER_1);
                TextView btn2 = keypadBottomSheetDialog.findViewById(R.id.NUMBER_2);
                TextView btn3 = keypadBottomSheetDialog.findViewById(R.id.NUMBER_3);
                TextView btn4 = keypadBottomSheetDialog.findViewById(R.id.NUMBER_4);
                TextView btn5 = keypadBottomSheetDialog.findViewById(R.id.NUMBER_5);
                TextView btn6 = keypadBottomSheetDialog.findViewById(R.id.NUMBER_6);
                TextView btn7 = keypadBottomSheetDialog.findViewById(R.id.NUMBER_7);
                TextView btn8 = keypadBottomSheetDialog.findViewById(R.id.NUMBER_8);
                TextView btn9 = keypadBottomSheetDialog.findViewById(R.id.NUMBER_9);

                btnBackSpace.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        String currentText = keypadView.getText().toString();
                        if (!currentText.isEmpty()) {
                            keypadView.setText(currentText.substring(0, currentText.length() - 2));
                        }
                    }
                });

                btn0.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        // append to keypad textview
                        String currentText = keypadView.getText().toString();
                        keypadView.setText(currentText + "0");
                        // send to ivr
                        sendIvrIntent(Constants.ACTION_SEND_IVR, "0");

                    }
                });
                btn1.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        // append to keypad textview
                        String currentText = keypadView.getText().toString();
                        keypadView.setText(currentText + "1");
                        // send to ivr
                        sendIvrIntent(Constants.ACTION_SEND_IVR, "1");

                    }
                });
                btn2.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        // append to keypad textview
                        String currentText = keypadView.getText().toString();
                        keypadView.setText(currentText + "2");
                        // send to ivr
                        sendIvrIntent(Constants.ACTION_SEND_IVR, "2");

                    }
                });
                btn3.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        // append to keypad textview
                        String currentText = keypadView.getText().toString();
                        keypadView.setText(currentText + "3");
                        // send to ivr
                        sendIvrIntent(Constants.ACTION_SEND_IVR, "3");

                    }
                });
                btn4.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        // append to keypad textview
                        String currentText = keypadView.getText().toString();
                        keypadView.setText(currentText + "4");
                        // send to ivr
                        sendIvrIntent(Constants.ACTION_SEND_IVR, "4");

                    }
                });
                btn5.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        // append to keypad textview
                        String currentText = keypadView.getText().toString();
                        keypadView.setText(currentText + "5");
                        // send to ivr
                        sendIvrIntent(Constants.ACTION_SEND_IVR, "5");

                    }
                });
                btn6.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        // append to keypad textview
                        String currentText = keypadView.getText().toString();
                        keypadView.setText(currentText + "6");
                        // send to ivr
                        sendIvrIntent(Constants.ACTION_SEND_IVR, "6");

                    }
                });
                btn7.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        // append to keypad textview
                        String currentText = keypadView.getText().toString();
                        keypadView.setText(currentText + "7");
                        // send to ivr
                        sendIvrIntent(Constants.ACTION_SEND_IVR, "7");

                    }
                });
                btn3.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        // append to keypad textview
                        String currentText = keypadView.getText().toString();
                        keypadView.setText(currentText + "8");
                        // send to ivr
                        sendIvrIntent(Constants.ACTION_SEND_IVR, "8");

                    }
                });
                btn9.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        // append to keypad textview
                        String currentText = keypadView.getText().toString();
                        keypadView.setText(currentText + "9");
                        // send to ivr
                        sendIvrIntent(Constants.ACTION_SEND_IVR, "9");

                    }
                });


                isKeypadOpen = !isKeypadOpen;
                applyFabState(btnKeypad, isKeypadOpen);
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

        if (enabled) {
            colorStateList = ColorStateList.valueOf(ContextCompat.getColor(this, R.color.white_55));
        } else {
            colorStateList = ColorStateList.valueOf(ContextCompat.getColor(this, R.color.accent));
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            button.setBackgroundTintList(colorStateList);
        }
    }

    private void sendIntent(String action) {
        Log.d(TAG, "Sending intent");
        Log.d(TAG, action);
        Intent activeCallIntent = new Intent();
        activeCallIntent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        activeCallIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        activeCallIntent.setAction(action);
        LocalBroadcastManager.getInstance(this).sendBroadcast(activeCallIntent);
    }

    private void sendIvrIntent(String action, String ivrNumber) {
        Log.d(TAG, "Sending intent");
        Log.d(TAG, action);
        Intent activeCallIntent = new Intent();
        activeCallIntent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        activeCallIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        activeCallIntent.setAction(action);
        activeCallIntent.putExtra(Constants.IVR_DIGIT, ivrNumber);
        LocalBroadcastManager.getInstance(this).sendBroadcast(activeCallIntent);
    }

    private void callCanceled() {
        finish();
    }


    @Override
    protected void onDestroy() {
        super.onDestroy();
        deactivateSensor();
    }

}