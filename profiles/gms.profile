# Google Play services system OTA allowlist.
# Syntax: component|package|fully.qualified.Component|core-or-optional
# At least one selected core target must exist for a user to be supported.
component|com.google.android.gms|com.google.android.gms.update.SystemUpdateService|core
component|com.google.android.gms|com.google.android.gms.update.SystemUpdateGcmTaskService|optional
component|com.google.android.gms|com.google.android.gms.update.UpdateFromSdCardService|optional
component|com.google.android.gms|com.google.android.gms.update.SystemUpdatePersistentListenerService|optional
component|com.google.android.gms|com.google.android.gms.update.UucNotificationReceiverService|optional
component|com.google.android.gms|com.google.android.gms.update.UpdateJobService|optional
component|com.google.android.gms|com.google.android.gms.update.SystemUpdateActivity|optional
component|com.google.android.gms|com.google.android.gms.update.phone.PopupDialog|optional
component|com.google.android.gms|com.google.android.gms.update.UpdateFromSdCardActivity|optional
component|com.google.android.gms|com.google.android.gms.update.OtaSuggestionActivity|optional
component|com.google.android.gms|com.google.android.gms.update.OtaSuggestionSummaryProvider|optional
component|com.google.android.gms|com.google.android.gms.update.resumeonreboot.ResumeOnRebootEscrowService|optional
component|com.google.android.gms|com.google.android.gms.update.SystemUpdateService$ActiveReceiver|optional
component|com.google.android.gms|com.google.android.gms.update.SystemUpdateService$Receiver|optional
component|com.google.android.gms|com.google.android.gms.update.SystemUpdateService$SecretCodeReceiver|optional
