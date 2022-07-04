/*
Copyright 2016 The Kubernetes Authors All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package systemlogmonitor

import (
	"encoding/json"
	"io/ioutil"
	v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/watch"
	clientset "k8s.io/client-go/kubernetes"
	v12 "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/heapster/common/kubernetes"
	"k8s.io/node-problem-detector/cmd/options"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"fmt"
	"time"

	"github.com/golang/glog"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/node-problem-detector/pkg/problemdaemon"
	"k8s.io/node-problem-detector/pkg/problemmetrics"
	"k8s.io/node-problem-detector/pkg/systemlogmonitor/logwatchers"
	watchertypes "k8s.io/node-problem-detector/pkg/systemlogmonitor/logwatchers/types"
	logtypes "k8s.io/node-problem-detector/pkg/systemlogmonitor/types"
	systemlogtypes "k8s.io/node-problem-detector/pkg/systemlogmonitor/types"
	"k8s.io/node-problem-detector/pkg/types"
	"k8s.io/node-problem-detector/pkg/util"
	"k8s.io/node-problem-detector/pkg/util/tomb"
	"k8s.io/node-problem-detector/pkg/version"
)

const (
	SystemLogMonitorName = "system-log-monitor"
	OOMREASON            = "PodOOMKilling"
)

var (
	uuidRegx        *regexp.Regexp
	k8sClient       *clientset.Clientset
	nodeName        string
	podEventTimeout = int64(3) // 3 minutes
)

func init() {
	problemdaemon.Register(
		SystemLogMonitorName,
		types.ProblemDaemonHandler{
			CreateProblemDaemonOrDie: NewLogMonitorOrDie,
			CmdOptionDescription:     "Set to config file paths."})
}

func init() {
	uuidRegx = regexp.MustCompile("[0-9a-f]{8}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{12}")
}

type logMonitor struct {
	configPath    string
	watcher       watchertypes.LogWatcher
	buffer        LogBuffer
	config        MonitorConfig
	conditions    []types.Condition
	logCh         <-chan *logtypes.Log
	output        chan *types.Status
	tomb          *tomb.Tomb
	podList       []v1.Pod
	rwLock        sync.RWMutex
	listOptions   metav1.ListOptions
	listerWatcher v12.PodInterface
}

func InitK8sClientOrDie(options *options.NodeProblemDetectorOptions) *clientset.Clientset {
	uri, _ := url.Parse(options.ApiServerOverride)
	cfg, err := kubernetes.GetKubeClientConfig(uri)
	if err != nil {
		panic(err)
	}
	cfg.UserAgent = fmt.Sprintf("%s/%s", filepath.Base(os.Args[0]), version.Version())
	k8sClient = clientset.NewForConfigOrDie(cfg)
	nodeName = options.NodeName
	return k8sClient
}

// NewLogMonitorOrDie create a new LogMonitor, panic if error occurs.
func NewLogMonitorOrDie(configPath string) types.Monitor {
	l := &logMonitor{
		configPath: configPath,
		tomb:       tomb.NewTomb(),
		rwLock:     sync.RWMutex{},
		listOptions: metav1.ListOptions{
			FieldSelector:   fmt.Sprintf("spec.nodeName=%s", nodeName),
			ResourceVersion: "0",
			TimeoutSeconds:  &podEventTimeout,
		},
		podList: make([]v1.Pod, 0),
	}

	f, err := ioutil.ReadFile(configPath)
	if err != nil {
		glog.Fatalf("Failed to read configuration file %q: %v", configPath, err)
	}
	err = json.Unmarshal(f, &l.config)
	if err != nil {
		glog.Fatalf("Failed to unmarshal configuration file %q: %v", configPath, err)
	}
	// Apply default configurations
	(&l.config).ApplyDefaultConfiguration()
	err = l.config.ValidateRules()
	if err != nil {
		glog.Fatalf("Failed to validate %s matching rules %+v: %v", l.configPath, l.config.Rules, err)
	}
	glog.Infof("Finish parsing log monitor config file %s: %+v", l.configPath, l.config)

	l.watcher = logwatchers.GetLogWatcherOrDie(l.config.WatcherConfig)
	l.buffer = NewLogBuffer(l.config.BufferSize)
	// A 1000 size channel should be big enough.
	l.output = make(chan *types.Status, 1000)

	if *l.config.EnableMetricsReporting {
		initializeProblemMetricsOrDie(l.config.Rules)
	}
	return l
}

// initializeProblemMetricsOrDie creates problem metrics for all problems and set the value to 0,
// panic if error occurs.
func initializeProblemMetricsOrDie(rules []systemlogtypes.Rule) {
	for _, rule := range rules {
		if rule.Type == types.Perm {
			err := problemmetrics.GlobalProblemMetricsManager.SetProblemGauge(rule.Condition, rule.Reason, false)
			if err != nil {
				glog.Fatalf("Failed to initialize problem gauge metrics for problem %q, reason %q: %v",
					rule.Condition, rule.Reason, err)
			}
		}
		err := problemmetrics.GlobalProblemMetricsManager.IncrementProblemCounter(rule.Reason, 0)
		if err != nil {
			glog.Fatalf("Failed to initialize problem counter metrics for %q: %v", rule.Reason, err)
		}
	}
}

func (l *logMonitor) Start() (<-chan *types.Status, error) {
	glog.Infof("Start log monitor %s", l.configPath)
	var err error
	l.listerWatcher = k8sClient.CoreV1().Pods("")
	l.logCh, err = l.watcher.Watch()
	if err != nil {
		return nil, err
	}
	go l.listAndWatch()
	go l.monitorLoop()
	return l.output, nil
}

func (l *logMonitor) Stop() {
	glog.Infof("Stop log monitor %s", l.configPath)
	l.tomb.Stop()
}

// monitorLoop is the main loop of log monitor.
func (l *logMonitor) monitorLoop() {
	defer func() {
		close(l.output)
		l.tomb.Done()
	}()
	l.initializeStatus()
	for {
		select {
		case log, ok := <-l.logCh:
			if !ok {
				glog.Errorf("Log channel closed: %s", l.configPath)
				return
			}
			l.parseLog(log)
		case <-l.tomb.Stopping():
			l.watcher.Stop()
			glog.Infof("Log monitor stopped: %s", l.configPath)
			return
		}
	}
}

// parseLog parses one log line.
func (l *logMonitor) parseLog(log *logtypes.Log) {
	// Once there is new log, log monitor will push it into the log buffer and try
	// to match each rule. If any rule is matched, log monitor will report a status.
	l.buffer.Push(log)
	for _, rule := range l.config.Rules {
		matched := l.buffer.Match(rule.Pattern)
		if len(matched) == 0 {
			continue
		}
		status := l.generateStatus(matched, rule)
		glog.Infof("New status generated: %+v", status)
		l.output <- status
	}
}

// generateStatus generates status from the logs.
func (l *logMonitor) generateStatus(logs []*logtypes.Log, rule systemlogtypes.Rule) *types.Status {
	// We use the timestamp of the first log line as the timestamp of the status.
	timestamp := logs[0].Timestamp
	message := generateMessage(logs)
	if rule.Reason == OOMREASON && l.listerWatcher != nil {
		uuid := string(uuidRegx.Find([]byte(message)))
		uuid = strings.ReplaceAll(uuid, "_", "-")

		// visit cache to get podList
		l.rwLock.RLock()
		// if cache is empty, list pods
		if l.podList == nil || len(l.podList) <= 0 {
			if err := l.list(); err != nil {
				glog.Errorf("Failed to list pods, err:%v", err)
			}
		}

		message = l.generateOOMMessage(uuid)
		l.rwLock.RUnlock()
	}

	if l.listerWatcher == nil {
		glog.Errorf("Empty ListAndWatcher!")
	}

	var events []types.Event
	var changedConditions []*types.Condition
	if rule.Type == types.Temp {
		// For temporary error only generate event
		events = append(events, types.Event{
			Severity:  types.Warn,
			Timestamp: timestamp,
			Reason:    rule.Reason,
			Message:   message,
		})
	} else {
		// For permanent error changes the condition
		for i := range l.conditions {
			condition := &l.conditions[i]
			if condition.Type == rule.Condition {
				// Update transition timestamp and message when the condition
				// changes. Condition is considered to be changed only when
				// status or reason changes.
				if condition.Status == types.False || condition.Reason != rule.Reason {
					condition.Transition = timestamp
					condition.Message = message
					events = append(events, util.GenerateConditionChangeEvent(
						condition.Type,
						types.True,
						rule.Reason,
						timestamp,
						condition.Message,
					))
				}
				condition.Status = types.True
				condition.Reason = rule.Reason
				changedConditions = append(changedConditions, condition)
				break
			}
		}
	}

	if *l.config.EnableMetricsReporting {
		for _, event := range events {
			err := problemmetrics.GlobalProblemMetricsManager.IncrementProblemCounter(event.Reason, 1)
			if err != nil {
				glog.Errorf("Failed to update problem counter metrics for %q: %v", event.Reason, err)
			}
		}
		for _, condition := range changedConditions {
			err := problemmetrics.GlobalProblemMetricsManager.SetProblemGauge(
				condition.Type, condition.Reason, condition.Status == types.True)
			if err != nil {
				glog.Errorf("Failed to update problem gauge metrics for problem %q, reason %q: %v",
					condition.Type, condition.Reason, err)
			}
		}
	}

	return &types.Status{
		Source: l.config.Source,
		// TODO(random-liu): Aggregate events and conditions and then do periodically report.
		Events:     events,
		Conditions: l.conditions,
	}
}

// initializeStatus initializes the internal condition and also reports it to the node problem detector.
func (l *logMonitor) initializeStatus() {
	// Initialize the default node conditions
	l.conditions = initialConditions(l.config.DefaultConditions)
	glog.Infof("Initialize condition generated: %+v", l.conditions)
	// Update the initial status
	l.output <- &types.Status{
		Source:     l.config.Source,
		Conditions: l.conditions,
	}
}

// listAndWatch watch and watch handle.
func (l *logMonitor) listAndWatch() {
	if err := l.list(); err != nil {
		glog.Errorf("Failed to init podList, err:%v", err)
	}

	for {
		w, err := l.listerWatcher.Watch(l.listOptions)
		if err != nil {
			glog.Errorf("Failed to watch pod, err:%v", err)
			return
		}

		select {
		case event := <-w.ResultChan():
			switch event.Type {
			case watch.Added:
				if err = l.list(); err != nil {
					glog.Errorf("Failed to list pods, err:%v", err)
				}
				w.Stop()
			case watch.Modified:
				if err = l.list(); err != nil {
					glog.Errorf("Failed to list pods, err:%v", err)
				}
				w.Stop()
			case watch.Deleted:
				if err = l.list(); err != nil {
					glog.Errorf("Failed to list pods, err:%v", err)
				}
				w.Stop()
			default:
				// glog.Errorf("Invalid watch event %v", event.Type)
				w.Stop()
			}
		case <-l.tomb.Stopping():
			w.Stop()
			glog.Infof("Log monitor stopped at %s", time.Now().Format("2006-01-02 15:04:05 MST Mon"))
			return
		}
	}
}

// syncWith sync logMonitor's podList cache.
// write lock inside.
func (l *logMonitor) syncWith(obj runtime.Object, resourceVersion string) error {
	list, ok := obj.(*v1.PodList)
	if !ok {
		return fmt.Errorf("cannot convert obj %v to podList", obj)
	}

	l.rwLock.Lock()
	defer l.rwLock.Unlock()
	l.podList = list.Items
	l.listOptions.ResourceVersion = resourceVersion
	return nil
}

// list lists pods with FieldSelector and resourceVersion.
func (l *logMonitor) list() error {
	var (
		list              runtime.Object
		err               error
		listMetaInterface meta.List
	)
	if list, err = l.listerWatcher.List(l.listOptions); err != nil {
		return err
	}
	if listMetaInterface, err = meta.ListAccessor(list); err != nil {
		return err
	}
	resourceVersion := listMetaInterface.GetResourceVersion()

	err = l.syncWith(list, resourceVersion)
	return err
}

// generateOOMMessage get oom pod message.
// need read lock before use.
func (l *logMonitor) generateOOMMessage(uuid string) string {
	l.rwLock.RLock()
	defer l.rwLock.RUnlock()
	for _, pod := range l.podList {
		if string(pod.UID) == uuid {
			return fmt.Sprintf("pod was OOM killed. node:%s pod:%s namespace:%s uuid:%s",
				pod.Spec.NodeName, pod.Name, pod.Namespace, uuid)
		}
	}
	return ""
}

func initialConditions(defaults []types.Condition) []types.Condition {
	conditions := make([]types.Condition, len(defaults))
	copy(conditions, defaults)
	for i := range conditions {
		conditions[i].Status = types.False
		conditions[i].Transition = time.Now()
	}
	return conditions
}

func generateMessage(logs []*logtypes.Log) string {
	messages := []string{}
	for _, log := range logs {
		messages = append(messages, log.Message)
	}
	return concatLogs(messages)
}
