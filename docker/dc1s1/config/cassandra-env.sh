# DSE Config Version: 6.7.17

# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

calculate_system_memory_sizes()
{
    if [ "$system_memory_sizes_calculated" = true ] ; then
        return
    fi

    case "`uname`" in
        Linux)
            system_memory_in_mb=`free -m | awk '/:/ {print $2;exit}'`
            system_cpu_cores=`egrep -c 'processor([[:space:]]+):.*' /proc/cpuinfo`
        ;;
        FreeBSD)
            system_memory_in_bytes=`sysctl hw.physmem | awk '{print $2}'`
            system_memory_in_mb=`expr $system_memory_in_bytes / 1024 / 1024`
            system_cpu_cores=`sysctl hw.ncpu | awk '{print $2}'`
        ;;
        SunOS)
            system_memory_in_mb=`prtconf | awk '/Memory size:/ {print $3}'`
            system_cpu_cores=`psrinfo | wc -l`
        ;;
        Darwin)
            system_memory_in_bytes=`sysctl hw.memsize | awk '{print $2}'`
            system_memory_in_mb=`expr $system_memory_in_bytes / 1024 / 1024`
            system_cpu_cores=`sysctl hw.ncpu | awk '{print $2}'`
        ;;
        *)
            # assume reasonable defaults for e.g. a modern desktop or
            # cheap server
            system_memory_in_mb="2048"
            system_cpu_cores="2"
        ;;
    esac

    # some systems like the raspberry pi don't report cores, use at least 1
    if [ "$system_cpu_cores" -lt "1" ]
    then
        system_cpu_cores="1"
    fi

    # cap here to 32765M because the JVM switches to 64 bit references at 32767M
    # details are described in http://java-performance.info/over-32g-heap-java/
    capped_heap_size="32765"

    # set max heap size based on the following
    # max(min(1/2 ram, 1024MB), min(1/4 ram, 8GB))
    # calculate 1/2 ram and cap to 1024MB
    # calculate 1/4 ram and cap to capped_heap_size
    # pick the max
    half_system_memory_in_mb=`expr $system_memory_in_mb / 2`
    quarter_system_memory_in_mb=`expr $half_system_memory_in_mb / 2`
    if [ "$half_system_memory_in_mb" -gt "1024" ]
    then
        half_system_memory_in_mb="1024"
    fi
    if [ "$quarter_system_memory_in_mb" -gt "$capped_heap_size" ]
    then
        quarter_system_memory_in_mb="$capped_heap_size"
    fi
    if [ "$half_system_memory_in_mb" -gt "$quarter_system_memory_in_mb" ]
    then
        max_heap_size_in_mb="$half_system_memory_in_mb"
    else
        max_heap_size_in_mb="$quarter_system_memory_in_mb"
    fi

    if [ "$JVM_VENDOR" = "Azul" ]; then
        # DSP-14197: round it down to the next even number as the Zing JDK has a bug were -Xmx numbers might be rounded
        # down and we would end up with -Xms being 1 larger than -Xmx and startup would fail.
        max_heap_size_in_mb=$(( ${max_heap_size_in_mb} - (${max_heap_size_in_mb} % 2) ))
    fi
    system_memory_sizes_calculated=true
}

calculate_system_memory_sizes

calculate_heap_sizes()
{
    MAX_HEAP_SIZE="${max_heap_size_in_mb}M"

    # Young gen: min(max_sensible_per_modern_cpu_core * num_cores, 1/4 * heap size)
    max_sensible_yg_per_core_in_mb="100"
    max_sensible_yg_in_mb=`expr $max_sensible_yg_per_core_in_mb "*" $system_cpu_cores`

    desired_yg_in_mb=`expr $max_heap_size_in_mb / 4`

    if [ "$desired_yg_in_mb" -gt "$max_sensible_yg_in_mb" ]
    then
        HEAP_NEWSIZE="${max_sensible_yg_in_mb}M"
    else
        HEAP_NEWSIZE="${desired_yg_in_mb}M"
    fi
}

# Determine the sort of JVM we'll be running on.
java_ver_output=`"${JAVA:-java}" -version 2>&1`
jvmver=`echo "$java_ver_output" | grep '[openjdk|java] version' | awk -F'"' 'NR==1 {print $2}' | cut -d\- -f1`
JVM_VERSION=${jvmver%_*}
JVM_PATCH_VERSION=${jvmver#*_}

if [ "$JVM_VERSION" \< "1.8" ] || [ "$JVM_VERSION" \> "1.8.2" ] ; then
    echo "DSE 6.7 requires Java 8 update 151 or later. Java $JVM_VERSION is not supported."
    exit 1;
fi
if [ "$JVM_PATCH_VERSION" -lt 151 ] ; then
    echo "DSE 6.7 requires Java 8 update 151 or later. Java 8 update $JVM_PATCH_VERSION is not supported."
    exit 1;
fi

jvm=`echo "$java_ver_output" | grep -A 1 '[openjdk|java] version' | awk 'NR==2 {print $1}'`
case "$jvm" in
    OpenJDK)
        JVM_VENDOR=OpenJDK
        # this will be "64-Bit" or "32-Bit"
        JVM_ARCH=`echo "$java_ver_output" | awk 'NR==3 {print $2}'`
        ;;
    "Java(TM)")
        JVM_VENDOR=Oracle
        # this will be "64-Bit" or "32-Bit"
        JVM_ARCH=`echo "$java_ver_output" | awk 'NR==3 {print $3}'`
        ;;
    "Zing")
        JVM_VENDOR=Azul
        # this will be "64-Bit" or "32-Bit"
        JVM_ARCH=`echo "$java_ver_output" | awk 'NR==3 {print $2}'`
        ;;
    *)
        # Help fill in other JVM values
        JVM_VENDOR=other
        JVM_ARCH=unknown
        ;;
esac

#GC log path has to be defined here because it needs to access CASSANDRA_HOME
JVM_OPTS="$JVM_OPTS -Xloggc:${CASSANDRA_LOG_DIR}/gc.log"

# Here we create the arguments that will get passed to the jvm when
# starting cassandra.

# Read user-defined JVM options from jvm.options file
JVM_OPTS_FILE=$CASSANDRA_CONF/jvm.options
for opt in `grep "^-" $JVM_OPTS_FILE`
do
  JVM_OPTS="$JVM_OPTS $opt"
done

# Check what parameters were defined on jvm.options file to avoid conflicts
# The DEFINED_XXX variables will be set to 0 if the pattern matches and 1 otherwise
echo $JVM_OPTS | egrep -q "(^|\s)-Xmn"
DEFINED_XMN=$?
echo $JVM_OPTS | egrep -q "(^|\s)-Xmx"
DEFINED_XMX=$?
echo $JVM_OPTS | egrep -q "(^|\s)-Xms"
DEFINED_XMS=$?
echo $JVM_OPTS | egrep -q "(^|\s)-XX:\+UseConcMarkSweepGC"
USING_CMS=$?
echo $JVM_OPTS | egrep -q "(^|\s)-XX:\+UseG1GC"
USING_G1=$?
echo $JVM_OPTS | egrep -q "(^|\s)-XX:MaxDirectMemorySize="
DEFINED_MAXDM=$?

# Override MAX_HEAP_SIZE and HEAP_NEWSIZE to set the amount of memory
# to allocate to the JVM at start-up. Either export environment variables
# with those names or set -Xmx -Xms and -Xmn in jvm.options
# For production use you may wish to adjust this for your
# environment. MAX_HEAP_SIZE is the total amount of memory dedicated
# to the Java heap. HEAP_NEWSIZE refers to the size of the young
# generation. Both MAX_HEAP_SIZE and HEAP_NEWSIZE should be either set
# or not if using CMS GC (if you set one, set the other).
#
# The main trade-off for the young generation is that the larger it
# is, the longer GC pause times will be. The shorter it is, the more
# expensive GC will be (usually).

# Set env variables to the values from jvm.options if they are set
if [ $DEFINED_XMX -eq 0 ] && [ "x$MAX_HEAP_SIZE" = "x" ]; then
    MAX_HEAP_SIZE=`echo $JVM_OPTS | egrep -io "(^|\s)-Xmx[[:digit:]]+[G,M,K]?($|\s)" | egrep -io "[[:digit:]]+[G,M,K]?"`
fi

if [ $DEFINED_XMN -eq 0 ] && [ "x$HEAP_NEWSIZE" = "x" ]; then
    HEAP_NEWSIZE=`echo $JVM_OPTS | egrep -io "(^|\s)-Xmn[[:digit:]]+[G,M,K]?($|\s)" | egrep -io "[[:digit:]]+[G,M,K]?"`
fi

if [ $DEFINED_MAXDM -eq 0 ] && [ "x$MAX_DIRECT_MEMORY" = "x" ]; then
    MAX_DIRECT_MEMORY=`echo $JVM_OPTS | egrep -io "(^|\s)-XX:MaxDirectMemorySize=[[:digit:]]+[G,M,K]?($|\s)" | egrep -io "[[:digit:]]+[G,M,K]?"`
fi

# Set this to control the amount of arenas per-thread in glibc
#export MALLOC_ARENA_MAX=4

# only calculate the size if it's not set manually
if [ "x$MAX_HEAP_SIZE" = "x" ] && [ "x$HEAP_NEWSIZE" = "x" -o $USING_G1 -eq 0 ]; then
    calculate_heap_sizes
elif [ "x$MAX_HEAP_SIZE" = "x" ] ||  [ "x$HEAP_NEWSIZE" = "x" -a $USING_G1 -ne 0 ]; then
    echo "Please set or unset MAX_HEAP_SIZE and HEAP_NEWSIZE in pairs when using CMS GC (see cassandra-env.sh)"
    exit 1
fi

# Add warning message if JVM_OPTS variable contains more than 1 -Xmx value
XMX_COUNT=`echo $JVM_OPTS | egrep -io "(^|\s)-Xmx" | wc -l`
if [ $XMX_COUNT -gt 1 ]; then
    echo "WARNING: Found $XMX_COUNT -Xmx in JVM_OPTS while it should be one" 1>&2
fi

heap_size_in_mb=0
if echo "$MAX_HEAP_SIZE" | grep -qi "G$" ;
then
    heap_size_in_mb="$((${MAX_HEAP_SIZE%?} * 1024))"
elif  echo "$MAX_HEAP_SIZE" | grep -qi "M$" ;
then
    heap_size_in_mb="${MAX_HEAP_SIZE%?}"
elif  echo "$MAX_HEAP_SIZE" | grep -qi "K$" ;
then
    heap_size_in_mb="$((${MAX_HEAP_SIZE%?} / 1024))"
else
    heap_size_in_mb="$(($MAX_HEAP_SIZE / (1024 * 1024)))"
fi

memory_remaining_in_mb="$((${system_memory_in_mb} - ${heap_size_in_mb}))"

# Override MAX_DIRECT_MEMORY to set the maximum amount of direct memory (NIO direct buffers)
# that the JVM can use either by exporting an env variable called MAX_DIRECT_MEMORY or by adding
# -XX:MaxDirectMemorySize= in jvm.options

if [ "x$MAX_DIRECT_MEMORY" = "x" ] ; then
    # Calculate direct memory as 1/2 of memory available after heap:
    MAX_DIRECT_MEMORY="$((memory_remaining_in_mb / 2))M"
fi

# We only set -XX:MaxDirectMemorySize if not already set in jvm.options
if [ $DEFINED_MAXDM -ne 0 ]; then
    JVM_OPTS="$JVM_OPTS -XX:MaxDirectMemorySize=$MAX_DIRECT_MEMORY"
fi

if [ "x$MALLOC_ARENA_MAX" = "x" ] ; then
    export MALLOC_ARENA_MAX=4
fi

# We only set -Xms and -Xmx if they were not defined on jvm.options file
# If defined, both Xmx and Xms should be defined together.
if [ $DEFINED_XMX -ne 0 ] && [ $DEFINED_XMS -ne 0 ]; then
    JVM_OPTS="$JVM_OPTS -Xms${MAX_HEAP_SIZE}"
    JVM_OPTS="$JVM_OPTS -Xmx${MAX_HEAP_SIZE}"
elif [ $DEFINED_XMX -ne 0 ] || [ $DEFINED_XMS -ne 0 ]; then
    echo "Please set or unset -Xmx and -Xms flags in pairs on jvm.options file."
    exit 1
fi

# We only set -Xmn flag if it was not defined in jvm.options file
# and if the CMS GC is being used
# If defined, both Xmn and Xmx should be defined together.
if [ $DEFINED_XMN -eq 0 ] && [ $DEFINED_XMX -ne 0 ]; then
    echo "Please set or unset -Xmx and -Xmn flags in pairs on jvm.options file."
    exit 1
elif [ $DEFINED_XMN -ne 0 ] && [ $USING_CMS -eq 0 ]; then
    JVM_OPTS="$JVM_OPTS -Xmn${HEAP_NEWSIZE}"
fi

if [ "$JVM_ARCH" = "64-Bit" ] && [ $USING_CMS -eq 0 ]; then
    JVM_OPTS="$JVM_OPTS -XX:+UseCondCardMark"
fi

# provides hints to the JIT compiler
JVM_OPTS="$JVM_OPTS -XX:CompileCommandFile=$CASSANDRA_CONF/hotspot_compiler"

# add the jamm javaagent
JVM_OPTS="$JVM_OPTS -javaagent:$CASSANDRA_HOME/lib/jamm-0.3.2.jar"

# set jvm HeapDumpPath with CASSANDRA_HEAPDUMP_DIR
if [ "x$CASSANDRA_HEAPDUMP_DIR" != "x" ]; then
    JVM_OPTS="$JVM_OPTS -XX:HeapDumpPath=$CASSANDRA_HEAPDUMP_DIR/cassandra-`date +%s`-pid$$.hprof"
fi

# stop the jvm on OutOfMemoryError as it can result in some data corruption
# uncomment the preferred option
# ExitOnOutOfMemoryError and CrashOnOutOfMemoryError require a JRE greater or equals to 1.7 update 101 or 1.8 update 92
# For OnOutOfMemoryError we cannot use the JVM_OPTS variables because bash commands split words
# on white spaces without taking quotes into account
# JVM_OPTS="$JVM_OPTS -XX:+ExitOnOutOfMemoryError"
# JVM_OPTS="$JVM_OPTS -XX:+CrashOnOutOfMemoryError"
JVM_ON_OUT_OF_MEMORY_ERROR_OPT="-XX:OnOutOfMemoryError=kill -9 %p"

# print an heap histogram on OutOfMemoryError
# JVM_OPTS="$JVM_OPTS -Dcassandra.printHeapHistogramOnOutOfMemoryError=true"

# jmx: metrics and administration interface
#
# add this if you're having trouble connecting:
# JVM_OPTS="$JVM_OPTS -Djava.rmi.server.hostname=<public name>"
#
# see
# https://blogs.oracle.com/jmxetc/entry/troubleshooting_connection_problems_in_jconsole
# for more on configuring JMX through firewalls, etc. (Short version:
# get it working with no firewall first.)
#
# Cassandra ships with JMX accessible *only* from localhost.
# To enable remote JMX connections, uncomment lines below
# with authentication and/or ssl enabled. See https://wiki.apache.org/cassandra/JmxSecurity
#
if [ "x$LOCAL_JMX" = "x" ]; then
    LOCAL_JMX=yes
fi

# Specifies the default port over which Cassandra will be available for
# JMX connections.
# For security reasons, you should not expose this port to the internet.  Firewall it if needed.
JMX_PORT="7199"

if [ "$LOCAL_JMX" = "yes" ]; then
  JVM_OPTS="$JVM_OPTS -Dcassandra.jmx.local.port=$JMX_PORT"
  JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.authenticate=false"
else
  JVM_OPTS="$JVM_OPTS -Dcassandra.jmx.remote.port=$JMX_PORT"
  # if ssl is enabled the same port cannot be used for both jmx and rmi so either
  # pick another value for this property or comment out to use a random port (though see CASSANDRA-7087 for origins)
  JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.rmi.port=$JMX_PORT"

  # turn on JMX authentication. See below for further options
  JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.authenticate=true"

  # jmx ssl options
  #JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.ssl=true"
  #JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.ssl.need.client.auth=true"
  #JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.ssl.enabled.protocols=<enabled-protocols>"
  #JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.ssl.enabled.cipher.suites=<enabled-cipher-suites>"
  #JVM_OPTS="$JVM_OPTS -Djavax.net.ssl.keyStore=/path/to/keystore"
  #JVM_OPTS="$JVM_OPTS -Djavax.net.ssl.keyStoreType=<keystore-type>"
  #JVM_OPTS="$JVM_OPTS -Djavax.net.ssl.keyStorePassword=<keystore-password>"
  #JVM_OPTS="$JVM_OPTS -Djavax.net.ssl.trustStore=/path/to/truststore"
  #JVM_OPTS="$JVM_OPTS -Djavax.net.ssl.trustStoreType=<truststore-type>"
  #JVM_OPTS="$JVM_OPTS -Djavax.net.ssl.trustStorePassword=<truststore-password>"
fi

# jmx authentication and authorization options. By default, auth is only
# activated for remote connections but they can also be enabled for local only JMX
## Basic file based authn & authz
JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.password.file=/etc/cassandra/jmxremote.password"
#JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.access.file=/etc/cassandra/jmxremote.access"
## Custom auth settings which can be used as alternatives to JMX's out of the box auth utilities.
## JAAS login modules can be used for authentication by uncommenting these two properties.
## Cassandra ships with a LoginModule implementation - org.apache.cassandra.auth.CassandraLoginModule -
## which delegates to the IAuthenticator configured in cassandra.yaml. See the sample JAAS configuration
## file cassandra-jaas.config
#JVM_OPTS="$JVM_OPTS -Dcassandra.jmx.remote.login.config=CassandraLogin"
#JVM_OPTS="$JVM_OPTS -Djava.security.auth.login.config=$CASSANDRA_HOME/conf/cassandra-jaas.config"

## Cassandra also ships with a helper for delegating JMX authz calls to the configured IAuthorizer,
## uncomment this to use it. Requires one of the two authentication options to be enabled
#JVM_OPTS="$JVM_OPTS -Dcassandra.jmx.authorizer=org.apache.cassandra.auth.jmx.AuthorizationProxy"

# To use mx4j, an HTML interface for JMX, add mx4j-tools.jar to the lib/
# directory.
# See http://wiki.apache.org/cassandra/Operations#Monitoring_with_MX4J
# By default mx4j listens on 0.0.0.0:8081. Uncomment the following lines
# to control its listen address and port.
#MX4J_ADDRESS="127.0.0.1"
#MX4J_PORT="8081"

if [ "x$MX4J_ADDRESS" = "x" ]; then
    # override default of 0.0.0.0 if no MX4J_ADDRESS is specified
    MX4J_ADDRESS="127.0.0.1"
fi
if echo "$MX4J_ADDRESS" | grep -qi '\-Dmx4jaddress=' ; then
    # Backward compatible with the older style #13578
    JVM_OPTS="$JVM_OPTS $MX4J_ADDRESS"
else
    JVM_OPTS="$JVM_OPTS -Dmx4jaddress=$MX4J_ADDRESS"
fi
if [ "x$MX4J_PORT" != "x" ]; then
    if echo "$MX4J_PORT" | grep -qi '\-Dmx4jport='; then
        # Backward compatible with the older style #13578
        JVM_OPTS="$JVM_OPTS $MX4J_PORT"
    else
        JVM_OPTS="$JVM_OPTS -Dmx4jport=$MX4J_PORT"
    fi
fi

# Cassandra uses SIGAR to capture OS metrics CASSANDRA-7838
# for SIGAR we have to set the java.library.path
# to the location of the native libraries.
JVM_OPTS="$JVM_OPTS -Djava.library.path=$JAVA_LIBRARY_PATH"

# We need to expose the available system memory so that the
# MemoryOnlyStrategy can do proper fraction calculations.
# See max_memory_to_lock_fraction setting in cassandra.yaml for details.
JVM_OPTS="$JVM_OPTS -Ddse.system_memory_in_mb=$system_memory_in_mb"

# Disable Agrona bounds check for extra performance
JVM_OPTS="$JVM_OPTS -Dagrona.disable.bounds.checks=TRUE"

JVM_OPTS="$JVM_OPTS $JVM_EXTRA_OPTS"

# add the DSE loader
JVM_OPTS="$JVM_OPTS $DSE_OPTS"
