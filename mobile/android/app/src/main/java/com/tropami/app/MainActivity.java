package com.tropami.app;

import android.os.Bundle;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        // wtyczki z kodu aplikacji rejestrujemy przed startem mostu
        registerPlugin(ShareToPlugin.class);
        super.onCreate(savedInstanceState);
    }
}
