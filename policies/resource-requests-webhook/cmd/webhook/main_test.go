package main

import (
	"encoding/json"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestValidateDeployment(t *testing.T) {
	tests := []struct {
		name        string
		containers  []corev1.Container
		init        []corev1.Container
		wantAllowed bool
	}{
		{
			name:        "allows containers with cpu and memory requests",
			containers:  []corev1.Container{containerWithRequests("app", "100m", "128Mi")},
			wantAllowed: true,
		},
		{
			name:        "denies missing memory request",
			containers:  []corev1.Container{containerWithRequests("app", "100m", "")},
			wantAllowed: false,
		},
		{
			name:        "denies missing cpu request",
			containers:  []corev1.Container{containerWithRequests("app", "", "128Mi")},
			wantAllowed: false,
		},
		{
			name:        "denies missing requests",
			containers:  []corev1.Container{{Name: "app"}},
			wantAllowed: false,
		},
		{
			name: "denies one invalid container",
			containers: []corev1.Container{
				containerWithRequests("valid", "100m", "128Mi"),
				containerWithRequests("invalid", "100m", ""),
			},
			wantAllowed: false,
		},
		{
			name:        "denies invalid init container",
			containers:  []corev1.Container{containerWithRequests("app", "100m", "128Mi")},
			init:        []corev1.Container{containerWithRequests("setup", "", "32Mi")},
			wantAllowed: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			raw, err := json.Marshal(appsv1.Deployment{
				TypeMeta: metav1.TypeMeta{
					APIVersion: "apps/v1",
					Kind:       "Deployment",
				},
				Spec: appsv1.DeploymentSpec{
					Template: corev1.PodTemplateSpec{
						Spec: corev1.PodSpec{
							Containers:     tt.containers,
							InitContainers: tt.init,
						},
					},
				},
			})
			if err != nil {
				t.Fatalf("marshal Deployment: %v", err)
			}

			allowed, _, err := validateDeployment(raw)
			if err != nil {
				t.Fatalf("validateDeployment: %v", err)
			}
			if allowed != tt.wantAllowed {
				t.Fatalf("validateDeployment() = %v, want %v", allowed, tt.wantAllowed)
			}
		})
	}
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
