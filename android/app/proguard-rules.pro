# Suppress warnings for desktop Java packages not present on Android runtime
-dontwarn java.beans.**
-dontwarn javax.xml.**
-dontwarn org.w3c.dom.bootstrap.**

# Jackson reflection, annotations, and metadata
-keepattributes *Annotation*,EnclosingMethod,Signature,InnerClasses
-keepclassmembers class * {
    @com.fasterxml.jackson.annotation.* <fields>;
    @com.fasterxml.jackson.annotation.* <methods>;
    @tools.jackson.annotation.* <fields>;
    @tools.jackson.annotation.* <methods>;
}
-dontwarn com.fasterxml.jackson.**
-dontwarn tools.jackson.**

# Preserve imageboard API model entities for Jackson deserialization
-keep class net.kodehawa.lib.imageboards.entities.** { *; }
-keep enum net.kodehawa.lib.imageboards.entities.** { *; }

# The ads SDK pulls in WorkManager 2.7.0 with Room 2.2.5, whose consumer rule
# keeps RoomDatabase subclasses but not their constructors. Room creates
# WorkDatabase_Impl reflectively, so R8 full mode would strip <init>() and
# crash androidx.startup at launch.
-keep class * extends androidx.room.RoomDatabase { <init>(); }

# OkHttp
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn javax.annotation.**
-dontwarn org.conscrypt.**
