package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"os/signal"
	"syscall"
	"time"

	admissionv1 "k8s.io/api/admission/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
)

const (
	maxRequestBodyBytes = 1 << 20
	shutdownTimeout     = 10 * time.Second
)

var (
	runtimeScheme = runtime.NewScheme()
	codecs        = serializer.NewCodecFactory(runtimeScheme)
	deserializer  = codecs.UniversalDeserializer()

	deploymentResource = metav1.GroupVersionResource{
		Group:    "apps",
		Version:  "v1",
		Resource: "deployments",
	}
)

func init() {
	utilruntime.Must(admissionv1.AddToScheme(runtimeScheme))
	utilruntime.Must(appsv1.AddToScheme(runtimeScheme))
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	var tlsCert string
	var tlsKey string
	var port string

	flag.StringVar(&tlsCert, "tls-cert", "/etc/webhook/certs/tls.crt", "path to TLS certificate")
	flag.StringVar(&tlsKey, "tls-key", "/etc/webhook/certs/tls.key", "path to TLS key")
	flag.StringVar(&port, "port", "8443", "webhook port")
	flag.Parse()

	mux := http.NewServeMux()
	mux.HandleFunc("/validate", serveValidate)
	mux.HandleFunc("/healthz", serveHealthz)

	server := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	serverErrors := make(chan error, 1)
	go func() {
		log.Printf("webhook listening on :%s", port)
		serverErrors <- server.ListenAndServeTLS(tlsCert, tlsKey)
	}()

	select {
	case err := <-serverErrors:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return fmt.Errorf("serve webhook: %w", err)
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()

		if err := server.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("shutdown webhook: %w", err)
		}

		err := <-serverErrors
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("serve webhook: %w", err)
		}
		return nil
	}
}

func serveHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodGet {
		_, _ = io.WriteString(w, "ok")
	}
}

func serveValidate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		http.Error(w, "Content-Type must be application/json", http.StatusUnsupportedMediaType)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBodyBytes)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "could not read request body", http.StatusBadRequest)
		return
	}
	if len(body) == 0 {
		http.Error(w, "empty body", http.StatusBadRequest)
		return
	}

	var review admissionv1.AdmissionReview
	if _, _, err := deserializer.Decode(body, nil, &review); err != nil {
		http.Error(w, fmt.Sprintf("could not decode request: %v", err), http.StatusBadRequest)
		return
	}
	if review.Request == nil {
		http.Error(w, "admission request is nil", http.StatusBadRequest)
		return
	}

	allowed, reason, validationErr := validateAdmissionRequest(review.Request)
	response := &admissionv1.AdmissionResponse{
		UID:     review.Request.UID,
		Allowed: allowed && validationErr == nil,
	}
	if validationErr != nil {
		response.Result = &metav1.Status{Message: validationErr.Error()}
	} else if !allowed {
		response.Result = &metav1.Status{Message: reason}
	}

	writeJSON(w, admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{
			APIVersion: admissionv1.SchemeGroupVersion.String(),
			Kind:       "AdmissionReview",
		},
		Response: response,
	})
}

func validateAdmissionRequest(request *admissionv1.AdmissionRequest) (bool, string, error) {
	if request.Resource != deploymentResource || request.SubResource != "" {
		return false, "", fmt.Errorf(
			"unsupported admission resource %s/%s/%s subresource %q",
			request.Resource.Group,
			request.Resource.Version,
			request.Resource.Resource,
			request.SubResource,
		)
	}

	if request.Operation != admissionv1.Create && request.Operation != admissionv1.Update {
		return false, "", fmt.Errorf("unsupported admission operation %q", request.Operation)
	}

	if len(request.Object.Raw) == 0 {
		return false, "", errors.New("admission object is empty")
	}

	return validateDeployment(request.Object.Raw)
}

func validateDeployment(raw []byte) (bool, string, error) {
	var deployment appsv1.Deployment
	if _, _, err := deserializer.Decode(raw, nil, &deployment); err != nil {
		return false, "", fmt.Errorf("decode Deployment: %w", err)
	}

	if allowed, reason := validateContainers("container", deployment.Spec.Template.Spec.Containers); !allowed {
		return false, reason, nil
	}
	if allowed, reason := validateContainers("init container", deployment.Spec.Template.Spec.InitContainers); !allowed {
		return false, reason, nil
	}

	return true, "", nil
}

func validateContainers(kind string, containers []corev1.Container) (bool, string) {
	for _, container := range containers {
		requests := container.Resources.Requests
		cpu, hasCPU := requests[corev1.ResourceCPU]
		memory, hasMemory := requests[corev1.ResourceMemory]

		if !hasCPU || cpu.IsZero() || !hasMemory || memory.IsZero() {
			return false, fmt.Sprintf(
				"%s %q must specify non-zero CPU and memory requests",
				kind,
				container.Name,
			)
		}
	}

	return true, ""
}

func writeJSON(w http.ResponseWriter, value any) {
	payload, err := json.Marshal(value)
	if err != nil {
		http.Error(w, "could not encode response", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if _, err := w.Write(payload); err != nil {
		log.Printf("write response: %v", err)
	}
}
