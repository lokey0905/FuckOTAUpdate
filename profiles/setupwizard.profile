# Optional: enable only after setup and after reviewing this ROM's OTA flow.
# These are explicit legacy OTA entries; newer CheckPlayEarlyUpdate* entries
# are deliberately excluded until their purpose is established.
component|com.google.android.setupwizard|com.google.android.setupwizard.update.OtaUpdateActivity|optional
component|com.google.android.setupwizard|com.google.android.setupwizard.update.PostCheckinAndUpdateActivity|optional
component|com.google.android.setupwizard|com.google.android.setupwizard.update.CompleteInFlightUpdates|optional
component|com.google.android.setupwizard|com.google.android.setupwizard.update.OtaUpdateCheck|optional
component|com.google.android.setupwizard|com.google.android.setupwizard.update.CompatEarlyUpdate|optional
component|com.google.android.setupwizard|com.google.android.setupwizard.update.EarlyUpdate|optional
