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

# OkHttp
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn javax.annotation.**
-dontwarn org.conscrypt.**
