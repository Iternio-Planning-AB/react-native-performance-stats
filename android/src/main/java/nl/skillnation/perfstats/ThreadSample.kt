package nl.skillnation.perfstats

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.WritableMap

class ThreadSample(
    var threadId: String,
    var threadName: String,
    var userTime: Double,
    var systemTime: Double,
    private var timestamp: Double
) {
    private var firstSeen: Double = timestamp
    private var lastUserTime = userTime
    private var lastSystemTime = systemTime
    private var lastTimestamp = timestamp

    fun update(newUserTime: Double, newSystemTime: Double, timestamp: Double) {
        // Save last state for delta computation next time
        this.lastUserTime = this.userTime
        this.lastSystemTime = this.systemTime
        this.lastTimestamp = this.timestamp

        this.userTime = newUserTime
        this.systemTime = newSystemTime
        this.timestamp = timestamp
    }

    fun toWritableMap(): WritableMap {
        val map = Arguments.createMap()

        map.putString("threadId", threadId)
        map.putString("threadName", threadName)
        map.putDouble("totalUserTimeSeconds", userTime)
        map.putDouble("totalSystemTimeSeconds", systemTime)
        map.putDouble("totalTimeSeconds", timestamp - firstSeen)

        if (timestamp == firstSeen) {
            map.putNull("deltaUserTimeSeconds")
            map.putNull("deltaSystemTimeSeconds")
            map.putNull("deltaTimeSeconds")
        } else {
            map.putDouble("deltaUserTimeSeconds", userTime - lastUserTime)
            map.putDouble("deltaSystemTimeSeconds", systemTime - lastSystemTime)
            map.putDouble("deltaTimeSeconds", timestamp - lastTimestamp)
        }

        return map
    }
}