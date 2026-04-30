plugins {
    `java-library`
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("tools.jackson.core:jackson-core:3.1.3")
    implementation("tools.jackson.core:jackson-databind:3.1.3")
    api("com.squareup.okhttp3:okhttp:5.3.2")
    implementation("org.slf4j:slf4j-api:2.0.18")
}

tasks.withType<JavaCompile>().configureEach {
    options.encoding = "UTF-8"
}
