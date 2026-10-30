package main

import (
	"encoding/json"
	"strings"
	"testing"

	admissionv1 "k8s.io/api/admission/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

func TestValidateDeployment(t *testing.T) {
	tests := []struct {
		name           string
		containers     []corev1.Container
		initContainers []corev1.Container
		wantAllowed    bool
		wantReason     string
	}{
		{
			name:        "allows containers with cpu and memory requests",
			containers:  []corev1.Container{containerWithRequests("app", "100m", "128Mi")},
			wantAllowed: true,
		},
		{
			name:           "allows valid init container",
			containers:     []corev1.Container{containerWithRequests("app", "100m", "128Mi")},
			initContainers: []corev1.Container{containerWithRequests("setup", "20m", "32Mi")},
			wantAllowed:    true,
		},
		{
			name:        "denies missing memory request",
			containers:  []corev1.Container{containerWithRequests("app", "100m", "")},
			wantAllowed: false,
			wantReason:  `container "app" must specify non-zero CPU and memory requests`,
		},
		{
			name:        "denies missing cpu request",
			containers:  []corev1.Container{containerWithRequests("app", "", "128Mi")},
			wantAllowed: false,
			wantReason:  `container "app" must specify non-zero CPU and memory requests`,
		},
		{
			name:        "denies missing requests",
			containers:  []corev1.Container{{Name: "app"}},
			wantAllowed: false,
			wantReason:  `container "app" must specify non-zero CPU and memory requests`,
		},
		{
			name: "denies one invalid container",
			containers: []corev1.Container{
				containerWithRequests("valid", "100m", "128Mi"),
				containerWithRequests("invalid", "100m", ""),
			},
			wantAllowed: false,
			wantReason:  `container "invalid" must specify non-zero CPU and memory requests`,
		},
		{
			name:           "denies invalid init container",
			containers:     []corev1.Container{containerWithRequests("app", "100m", "128Mi")},
			initContainers: []corev1.Container{containerWithRequests("setup", "", "32Mi")},
			wantAllowed:    false,
			wantReason:     `init container "setup" must specify non-zero CPU and memory requests`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			raw := deploymentJSON(t, tt.containers, tt.initContainers)

			allowed, reason, err := validateDeployment(raw)
			if err != nil {
				t.Fatalf("validateDeployment: %v", err)
			}
			if allowed != tt.wantAllowed {
				t.Fatalf("validateDeployment() allowed = %v, want %v", allowed, tt.wantAllowed)
			}
			if tt.wantReason != "" && reason != tt.wantReason {
				t.Fatalf("validateDeployment() reason = %q, want %q", reason, tt.wantReason)
			}
		})
	}
}

func TestValidateAdmissionRequest(t *testing.T) {
	validObject := deploymentJSON(
		t,
		[]corev1.Container{containerWithRequests("app", "100m", "128Mi")},
		nil,
	)

	tests := []struct {
		name        string
		request     admissionv1.AdmissionRequest
		wantAllowed bool
		wantErr     string
	}{
		{
			name: "allows deployment create",
			request: admissionv1.AdmissionRequest{
				Resource:  deploymentResource,
				Operation: admissionv1.Create,
				Object:    runtime.RawExtension{Raw: validObject},
			},
			wantAllowed: true,
		},
		{
			name: "allows deployment update",
			request: admissionv1.AdmissionRequest{
				Resource:  deploymentResource,
				Operation: admissionv1.Update,
				Object:    runtime.RawExtension{Raw: validObject},
			},
			wantAllowed: true,
		},
		{
			name: "rejects wrong resource",
			request: admissionv1.AdmissionRequest{
				Resource:  metav1.GroupVersionResource{Group: "apps", Version: "v1", Resource: "statefulsets"},
				Operation: admissionv1.Create,
				Object:    runtime.RawExtension{Raw: validObject},
			},
			wantErr: "unsupported admission resource",
		},
		{
			name: "rejects subresource",
			request: admissionv1.AdmissionRequest{
				Resource:    deploymentResource,
				SubResource: "scale",
				Operation:   admissionv1.Update,
				Object:      runtime.RawExtension{Raw: validObject},
			},
			wantErr: "unsupported admission resource",
		},
		{
			name: "rejects delete",
			request: admissionv1.AdmissionRequest{
				Resource:  deploymentResource,
				Operation: admissionv1.Delete,
				Object:    runtime.RawExtension{Raw: validObject},
			},
			wantErr: "unsupported admission operation",
		},
		{
			name: "rejects empty object",
			request: admissionv1.AdmissionRequest{
				Resource:  deploymentResource,
				Operation: admissionv1.Create,
			},
			wantErr: "admission object is empty",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			allowed, _, err := validateAdmissionRequest(&tt.request)
			if allowed != tt.wantAllowed {
				t.Fatalf("validateAdmissionRequest() allowed = %v, want %v", allowed, tt.wantAllowed)
			}

			if tt.wantErr == "" {
				if err != nil {
					t.Fatalf("validateAdmissionRequest() unexpected error: %v", err)
				}
				return
			}

			if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("validateAdmissionRequest() error = %v, want substring %q", err, tt.wantErr)
			}
		})
	}
}

func deploymentJSON(t *testing.T, containers, initContainers []corev1.Container) []byte {
	t.Helper()

	raw, err := json.Marshal(appsv1.Deployment{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "apps/v1",
			Kind:       "Deployment",
		},
		Spec: appsv1.DeploymentSpec{
			Template: corev1.PodTemplateSpec{
				Spec: corev1.PodSpec{
					Containers:     containers,
					InitContainers: initContainers,
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("marshal Deployment: %v", err)
	}
	return raw
}

func containerWithRequests(name, cpu, memory string) corev1.Container {
	requests := corev1.ResourceList{}
	if cpu != "" {
		requests[corev1.ResourceCPU] = resource.MustParse(cpu)
	}
	if memory != "" {
		requests[corev1.ResourceMemory] = resource.MustParse(memory)
	}

	return corev1.Container{
		Name: name,
		Resources: corev1.ResourceRequirements{
			Requests: requests,
		},
	}
}
