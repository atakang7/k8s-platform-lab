package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"

	admissionv1 "k8s.io/api/admission/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/serializer"
)

var (
	runtimeScheme = runtime.NewScheme()
	codecs        = serializer.NewCodecFactory(runtimeScheme)
	deserializer  = codecs.UniversalDeserializer()
)

func init() {
	_ = appsv1.AddToScheme(runtimeScheme)
	_ = corev1.AddToScheme(runtimeScheme)
}

func main() {
	var tlsCert, tlsKey, port string
	flag.StringVar(&tlsCert, "tls-cert", "/etc/webhook/certs/tls.crt", "Path to TLS certificate")
	flag.StringVar(&tlsKey, "tls-key", "/etc/webhook/certs/tls.key", "Path to TLS key")
	flag.StringVar(&port, "port", "8443", "Webhook port")
	flag.Parse()

	mux := http.NewServeMux()
	mux.HandleFunc("/validate", serveValidate)
	mux.HandleFunc("/healthz", serveHealthz)

	server := &http.Server{
		Addr:    fmt.Sprintf(":%s", port),
		Handler: mux,
	}

	log.Printf("Starting webhook on port %s", port)
	if err := server.ListenAndServeTLS(tlsCert, tlsKey); err != nil {
		log.Fatalf("Failed to listen and serve: %v", err)
	}
}

func serveHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

func serveValidate(w http.ResponseWriter, r *http.Request) {
	var body []byte
	if r.Body != nil {
		if data, err := io.ReadAll(r.Body); err == nil {
			body = data
		}
	}

	if len(body) == 0 {
		http.Error(w, "empty body", http.StatusBadRequest)
		return
	}

	contentType := r.Header.Get("Content-Type")
	if contentType != "application/json" {
		http.Error(w, "invalid Content-Type, expected `application/json`", http.StatusUnsupportedMediaType)
		return
	}

	var admissionReviewReq admissionv1.AdmissionReview
	if _, _, err := deserializer.Decode(body, nil, &admissionReviewReq); err != nil {
		http.Error(w, fmt.Sprintf("could not decode request: %v", err), http.StatusBadRequest)
		return
	}

	if admissionReviewReq.Request == nil {
		http.Error(w, "admission request is nil", http.StatusBadRequest)
		return
	}

	admissionReviewResponse := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "admission.k8s.io/v1",
			Kind:       "AdmissionReview",
		},
		Response: &admissionv1.AdmissionResponse{
			UID: admissionReviewReq.Request.UID,
		},
	}

	allowed, reason, err := validateDeployment(admissionReviewReq.Request.Object.Raw)
	if err != nil {
		admissionReviewResponse.Response.Allowed = false
		admissionReviewResponse.Response.Result = &metav1.Status{
			Message: err.Error(),
		}
	} else {
		admissionReviewResponse.Response.Allowed = allowed
		if !allowed {
			admissionReviewResponse.Response.Result = &metav1.Status{
				Message: reason,
			}
		}
	}

	respBytes, err := json.Marshal(admissionReviewResponse)
	if err != nil {
		http.Error(w, fmt.Sprintf("could not encode response: %v", err), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if _, err := w.Write(respBytes); err != nil {
		log.Printf("could not write response: %v", err)
	}
}

func validateDeployment(raw []byte) (bool, string, error) {
	var deployment appsv1.Deployment
	if _, _, err := deserializer.Decode(raw, nil, &deployment); err != nil {
		return false, "", fmt.Errorf("could not decode Deployment: %v", err)
	}

	for _, container := range deployment.Spec.Template.Spec.Containers {
		if container.Resources.Requests == nil {
			return false, fmt.Sprintf("container %q must specify both CPU and memory requests", container.Name), nil
		}

		cpuReq, hasCPU := container.Resources.Requests[corev1.ResourceCPU]
		memReq, hasMemory := container.Resources.Requests[corev1.ResourceMemory]

		if !hasCPU || cpuReq.IsZero() || !hasMemory || memReq.IsZero() {
			return false, fmt.Sprintf("container %q must specify both CPU and memory requests", container.Name), nil
		}
	}

	return true, "", nil
}
