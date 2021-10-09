# Copyright 2016 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ARG BASEIMAGE
FROM ${BASEIMAGE}

MAINTAINER Random Liu <lantaol@google.com>

#RUN clean-install util-linux libsystemd0 systemd bash lsof curl
RUN yum install -y systemd-239-45.3.al8
RUN systemctl --version

# Avoid symlink of /etc/localtime.
RUN test -h /etc/localtime && rm -f /etc/localtime && cp /usr/share/zoneinfo/UTC /etc/localtime || true

ADD ./bin/node-problem-detector /node-problem-detector
ARG LOGCOUNTER
COPY ./bin/health-checker ${LOGCOUNTER} /home/kubernetes/bin/

#ADD lib/libsystemd-shared-239.so /lib64/libsystemd-shared-239.so
#ADD lib/libip4tc.so.2.0.0 /lib64/libip4tc.so.2
#ADD lib/libcryptsetup.so.12.6.0 /lib64/libcryptsetup.so.12
#ADD lib/libpcap.so.1.9.1 /lib64/libpcap.so.1
#ADD lib/libseccomp.so.2.4.3 /lib64/libseccomp.so.2
#ADD lib/libdevmapper.so.1.02 /lib64/libdevmapper.so.1.02

COPY config /config
RUN chmod +x /config/plugin/*.sh
ENTRYPOINT ["/node-problem-detector", "--config.system-log-monitor=/config/kernel-monitor.json"]
